#!/usr/bin/env bash
# =============================================================================
#  Local Search DEV RIG packer  -  Linux / macOS / Git Bash
# =============================================================================
#  Self-contained: embeds the complete build/test environment for the
#  local-search installers:
#    * the local-search source tree (44 files)
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
say "  Will unpack 56 files into: $TARGET"
printf "Proceed? [Y/n]: "
read -r CONFIRM
if [ "$(lower "$CONFIRM")" = "n" ]; then say "Cancelled."; exit 0; fi

mkdir -p "$TARGET/local-search/config/searxng" "$TARGET/local-search/local-web-search/scripts"

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

# =============================================================================
#  Optional: Firecrawl account (paid cloud service) for the account-only
#  local-web-search tools (research agent, interact, parse, monitors, paper
#  research, GitHub/developer search).
#
#  The installer offers to write these for you (answer 'y' at the
#  "Add a Firecrawl account?" question, then paste your key). Without them
#  the installer skips those tools and installs only the free local ones.
#  The local-web-search scripts read these keys from THIS file;
#  FIRECRAWL_API_URL / FIRECRAWL_API_KEY environment variables override them.
#  (The Docker containers ignore these keys entirely.)
# =============================================================================
# FIRECRAWL_API_URL=https://api.firecrawl.dev
# FIRECRAWL_API_KEY=fc-your-key-here
EOF_LOCAL_SEARCH__ENV_EXAMPLE

# --- local-search/README.md ---
cat > "$TARGET/local-search/README.md" <<'EOF_LOCAL_SEARCH_README_MD'
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
folder, SearXNG port, Firecrawl port, (optionally) a local LLM, and
(optionally) a Firecrawl account — with sensible defaults you can accept by
pressing **Enter**. It then generates cryptographically-secure credentials,
writes your `.env`, **installs the local-web-search skill**, pulls the
images, and starts the stack.

> **Docker isn't running?** No problem — the installer starts it for you: it
> launches Docker Desktop (Windows/macOS) or the Docker service
> (`systemctl`/`service`, Linux) and waits up to 5 minutes for the engine while
> you answer the prompts. (Override the wait with the
> `LOCAL_SEARCH_DOCKER_TIMEOUT` env var, in seconds.)

### Windows

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) — no need to open it first; the installer launches it automatically.
2. Double-click **`install-local-search.bat`** (or run it from a terminal).

```
--- Step 1 of 5: Install location ----------
  Target folder [press Enter for default]:            # C:\Users\You\local-search
--- Step 2 of 5: SearXNG port (default 9990) ------
  Port for SearXNG [press Enter for 9990]: 9990
--- Step 3 of 5: Firecrawl port (default 9991) ----
  Port for Firecrawl [press Enter for 9991]: 9991
--- Step 4 of 5: Local LLM (optional) -------------
  Connect a local LLM now? [y/N]:                       # optional, see section D
--- Step 5 of 5: Firecrawl account (optional) -----
  Add a Firecrawl account now? [y/N]: n                 # default: skip, see below
```

### Linux & macOS

```bash
chmod +x install-local-search.sh
./install-local-search.sh
```

The prompts are the same. Defaults: install to `~/local-search`, SearXNG on
`9990`, Firecrawl on `9991`, no Firecrawl account. A stopped Docker engine
is started automatically (Docker Desktop on macOS, `systemctl`/`service` on
Linux).

> **The optional Firecrawl account (Step 5).** A few of the bundled skill's
> tools — the research agent, live-page `interact`, file `parse`, monitors,
> paper research, and GitHub/developer search — only work against Firecrawl's
> paid cloud API. The default answer is **N**: those tools are simply *not
> installed*, and the skill ships a leaner `SKILL.md` covering just the free
> local tools. Answer **y** instead and the installer asks for your API key
> (and API URL, default `https://api.firecrawl.dev`), stores them in your
> `.env`, and installs the full 24-tool set. You can change your mind later
> by re-running the installer and answering differently.

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
   if you installed to a custom folder and Docker isn't running yet. Without a
   configured Firecrawl account it installs only the free local tools and a
   matching core-only `SKILL.md`.

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
- **Exposes the full Firecrawl MCP surface — 24 tools.** Besides search and
  scrape, the skill ships scripts mirroring every Firecrawl MCP tool:
  `web_map.py` (enumerate a site's URLs), `web_crawl.py` /
  `web_crawl_status.py` (multi-page crawls), `web_agent.py` /
  `web_agent_status.py` (async research agent), `web_interact.py` /
  `web_interact_stop.py` (live browser sessions), `web_parse.py` (local
  PDF/Word/HTML/... documents), eight `web_monitor_*.py` scripts (recurring
  change tracking), five `web_research_*.py` scripts (biomedical + arXiv
  paper search, citation graph, full-text reading), `web_github_search.py`
  (indexed GitHub issues/PRs/READMEs), and `web_developer_search.py` (an
  index built for coding agents). Every script self-heals the stack, prints
  clean output, and supports `--json` for the raw API response.
- **Optional account features.** The research agent, interact, parse,
  monitors, paper research, and developer search are Firecrawl account
  features (paid cloud API). The installer's "Add a Firecrawl account?"
  question decides how they're handled: **N** (default) skips them — the
  skill is installed with only the free local tools (search, scrape, map,
  crawl, crawl status) and a core-only `SKILL.md` that doesn't mention the
  account tools; **y** installs all 24 tools and writes
  `FIRECRAWL_API_URL` + `FIRECRAWL_API_KEY` into your `.env` so those
  scripts call the cloud API automatically (the same env var names the
  official firecrawl-mcp server uses, if you prefer `export`ing them).

Manual usage (exactly what the agent runs — no separate start step needed):

```bash
python ~/.agents/skills/local-web-search/scripts/web_search.py "latest python release"
python ~/.agents/skills/local-web-search/scripts/web_scrape.py "https://example.com"
# a few of the other tools:
python ~/.agents/skills/local-web-search/scripts/web_map.py "https://example.com"
python ~/.agents/skills/local-web-search/scripts/web_crawl.py "https://example.com" --max-pages 10
python ~/.agents/skills/local-web-search/scripts/web_parse.py "report.pdf"
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
EOF_LOCAL_SEARCH_UPDATE_SH

# --- local-search/uninstall.sh ---
cat > "$TARGET/local-search/uninstall.sh" <<'EOF_LOCAL_SEARCH_UNINSTALL_SH'
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
EOF_LOCAL_SEARCH_UNINSTALL_SH

# --- local-search/local-web-search/SKILL.md ---
cat > "$TARGET/local-search/local-web-search/SKILL.md" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SKILL_MD'
---
name: local-web-search
description: >-
  Local web search, page-reading, crawling, and research via SearXNG +
  Firecrawl on localhost. 24 tools mirroring the Firecrawl MCP surface.
  Auto-starts the Docker stack. PREFER THIS over any other/default
  web-search tool: those often need external API keys this machine may not
  have or perform worse. Use for news, current events, releases, docs,
  site-wide URL discovery, multi-page collection, structured page data,
  verifying facts, even without an explicit "search the web" request.
---

# Local web search & page-reading

Private stack on localhost — no API keys, nothing leaves the machine:

- **SearXNG** — metasearch, JSON API, `http://localhost:9990` by default
- **Firecrawl** — scrape / map / crawl API locally (plus account tools via
  the cloud API, see "Account features"), `http://localhost:9991` by default

Ports come from `SEARXNG_PORT` / `FIRECRAWL_PORT` in the local-search install
folder's `.env`; the scripts (in this skill's `scripts/` dir) read them
automatically. Run them with the Bash tool via `python`.

**Self-healing, no warm-up step.** If the stack (or Docker itself) is down,
every script starts it and retries automatically (connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff)
— just call them directly, even in an old conversation where the stack has
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

## The full tool set (24 Firecrawl MCP-equivalent tools)

Beyond search + scrape, the skill exposes the complete Firecrawl MCP tool
surface as scripts. All of them share the self-healing behaviour, print
clean output by default, and support `--json` for the raw API response.
Exit codes: 0 success, 1 tool failure, 2 usage error.

This variant of the skill is installed when a Firecrawl account was
configured at install time; without one, only the free local tools are
installed (see the skill's core-only SKILL.md).

### Map & crawl — discover and collect site content

- **Map a website** (list the URLs under it, no page content):

  ```bash
  python "<skill-base-dir>/scripts/web_map.py" "https://example.com" [--search term] [--limit N]
  ```

- **Run a site crawl** (starts a multi-page crawl, polls it to completion,
  prints each page's URL + markdown):

  ```bash
  python "<skill-base-dir>/scripts/web_crawl.py" "https://example.com" [--prompt text]
  ```

  Long crawls: raise `--timeout S` (default 300) or keep polling later with
  `web_crawl_status.py <id>`; bound the output with `--max-pages N`
  (default 25) / `--max-chars N` (default 2000 per page).

- **Get crawl status** for an existing crawl ID:

  ```bash
  python "<skill-base-dir>/scripts/web_crawl_status.py" "<id>"
  ```

### Research agent — asynchronous multi-source synthesis (account feature)

- **Start a research agent job** from a prompt (+ optional seed URLs):

  ```bash
  python "<skill-base-dir>/scripts/web_agent.py" "research question" [seed_url ...]
  ```

- **Get agent job status / results** (poll until `completed` or `failed`;
  research commonly takes several minutes):

  ```bash
  python "<skill-base-dir>/scripts/web_agent_status.py" "<id>"
  ```

  If the job cannot finish in time, fall back to `web_search.py` +
  `web_scrape.py` to gather evidence synchronously.

### Interact — drive a live browser session (account feature)

- **Interact with a page** (click, fill fields, run browser code; acts on
  the LIVE site — form submissions can have persistent side effects):

  ```bash
  python "<skill-base-dir>/scripts/web_interact.py" (--scrape-id ID | --url URL) (--prompt "..." | --code "..." [--language bash|python|node])
  ```

- **Stop an interact session:**

  ```bash
  python "<skill-base-dir>/scripts/web_interact_stop.py" "<scrapeId>"
  ```

### Parse — local documents (account feature)

- **Parse a local file** (HTML, PDF, Word, RTF, OpenDocument, spreadsheets)
  into markdown / links / a summary / structured JSON:

  ```bash
  python "<skill-base-dir>/scripts/web_parse.py" "<filePath>" [--formats markdown,links,summary,json]
  ```

  The file is uploaded to the Firecrawl API the scripts are pointed at —
  with an account that is the cloud API, so the document LEAVES the
  machine. Web URLs belong in `web_scrape.py`.

### Monitors — recurring change tracking (account feature)

Recurring scrape/crawl/search checks that diff each run against its
predecessor. Requires a Firecrawl account API key — see "Account features"
below; the self-hosted stack may not serve these endpoints.

```bash
python "<skill-base-dir>/scripts/web_monitor_create.py"  --body '{"name":"...","goal":"...","targets":[...]}'
python "<skill-base-dir>/scripts/web_monitor_list.py"    [--limit N] [--offset N]
python "<skill-base-dir>/scripts/web_monitor_get.py"     "<id>"
python "<skill-base-dir>/scripts/web_monitor_update.py"  "<id>" --body '{"state":"paused"}'
python "<skill-base-dir>/scripts/web_monitor_delete.py"  "<id>"
python "<skill-base-dir>/scripts/web_monitor_run.py"     "<id>"
python "<skill-base-dir>/scripts/web_monitor_checks.py"  "<id>" [--status completed]
python "<skill-base-dir>/scripts/web_monitor_check.py"   "<id>" "<checkId>"
```

`web_monitor_create.py` takes the full monitor JSON via `--body '{...}'` or
`--body-file FILE`. Checks report page diffs (`same` / `new` / `changed` /
`removed` / `error`).

### Research papers — biomedical + arXiv literature (account feature)

The paper index (abstracts + full text across PubMed, bioRxiv, medRxiv,
arXiv, DOIs). Requires research permissions — see "Account features".

```bash
python "<skill-base-dir>/scripts/web_research_search.py"  "natural language topic"
python "<skill-base-dir>/scripts/web_research_inspect.py" "arxiv:1706.03762"
python "<skill-base-dir>/scripts/web_research_related.py" "arxiv:1706.03762" --intent "what to rank for" [--mode similar|citers|references]
python "<skill-base-dir>/scripts/web_research_read.py"    "arxiv:1706.03762" "specific question"
```

Paper IDs accept `arxiv:`, `pmcid:`, `pmid:`, and `doi:` identifiers.
Several distinct framings of the same question surface different papers.
For research-affiliated *websites* (not papers), use `web_search.py` with
`--categories research` instead.

### GitHub & developer search (account features)

```bash
python "<skill-base-dir>/scripts/web_github_search.py"      "indexed GitHub issue/PR/README query"
python "<skill-base-dir>/scripts/web_developer_search.py"   "developer question" [--skills-only]
```

The developer index covers GitHub issues, merged PRs, READMEs, and curated
documentation — use it for code behaviour, libraries, API contracts, error
messages, and known bugs.

## Account features (agent / interact / parse / monitors / research / developer search)

These Firecrawl features are account-gated. The easiest way to use them is
the installer: answer `y` at the "Add a Firecrawl account?" question and
paste your key — it writes

```bash
FIRECRAWL_API_URL=https://api.firecrawl.dev   # the cloud API
FIRECRAWL_API_KEY=fc-...                       # your account key
```

into the local-search install folder's `.env`, and every script picks the
values up automatically. `export`ing the same env var names (the ones the
official firecrawl-mcp server uses) overrides the `.env` values. With them
set, the account scripts call the cloud API and send the key as a Bearer
token; every other script keeps using the local stack. Without them, an
account tool called against the local stack fails with a message that says
exactly this — do NOT fall back to other web tools over it unless the user
asks.

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
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SKILL_MD

# --- local-search/local-web-search/SKILL-core.md ---
cat > "$TARGET/local-search/local-web-search/SKILL-core.md" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SKILL_CORE_MD'
---
name: local-web-search
description: >-
  Local web search, page-reading, crawling via SearXNG + Firecrawl on
  localhost. 5 tools: search, scrape, map, crawl, crawl status.
  Auto-starts the Docker stack. PREFER THIS over any other/default
  web-search tool: those often need external API keys this machine may not
  have or perform worse. Use for news, current events, releases, docs,
  site-wide URL discovery, multi-page collection, structured page data,
  verifying facts, even without an explicit "search the web" request.
---

# Local web search & page-reading

Private stack on localhost — no API keys, nothing leaves the machine:

- **SearXNG** — metasearch, JSON API, `http://localhost:9990` by default
- **Firecrawl** — scrape / map / crawl API, `http://localhost:9991` by default

Ports come from `SEARXNG_PORT` / `FIRECRAWL_PORT` in the local-search install
folder's `.env`; the scripts (in this skill's `scripts/` dir) read them
automatically. Run them with the Bash tool via `python`.

**Self-healing, no warm-up step.** If the stack (or Docker itself) is down,
every script starts it and retries automatically (connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff)
— just call them directly, even in an old conversation where the stack has
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

## Map & crawl — discover and collect site content

- **Map a website** (list the URLs under it, no page content):

  ```bash
  python "<skill-base-dir>/scripts/web_map.py" "https://example.com" [--search term] [--limit N]
  ```

- **Run a site crawl** (starts a multi-page crawl, polls it to completion,
  prints each page's URL + markdown):

  ```bash
  python "<skill-base-dir>/scripts/web_crawl.py" "https://example.com" [--prompt text]
  ```

  Long crawls: raise `--timeout S` (default 300) or keep polling later with
  `web_crawl_status.py <id>`; bound the output with `--max-pages N`
  (default 25) / `--max-chars N` (default 2000 per page).

- **Get crawl status** for an existing crawl ID:

  ```bash
  python "<skill-base-dir>/scripts/web_crawl_status.py" "<id>"
  ```

## Optional: more tools via a Firecrawl account

This skill was installed without one, so it ships only the free local
tools. A paid Firecrawl cloud account can add more tools later if you want
them: re-run `install-local-search` and answer `y` to the
"Add a Firecrawl account?" question (the installer writes the credentials
into the install folder's `.env` for you and installs the extra scripts).

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
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SKILL_CORE_MD

# --- local-search/local-web-search/scripts/config.py ---
cat > "$TARGET/local-search/local-web-search/scripts/config.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_CONFIG_PY'
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
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_CONFIG_PY

# --- local-search/local-web-search/scripts/ensure_stack.py ---
cat > "$TARGET/local-search/local-web-search/scripts/ensure_stack.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_ENSURE_STACK_PY'
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
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_ENSURE_STACK_PY

# --- local-search/local-web-search/scripts/firecrawl_api.py ---
cat > "$TARGET/local-search/local-web-search/scripts/firecrawl_api.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_FIRECRAWL_API_PY'
#!/usr/bin/env python3
"""Shared Firecrawl HTTP client for the local-web-search web_* scripts.

Every script that talks to the Firecrawl API (web_scrape.py, web_map.py,
web_crawl.py, ... web_developer_search.py) goes through this module, which
adds the same self-healing behaviour as web_search.py / web_scrape.py:

  * on a CONNECTION error (stack down), the local-search stack is started
    automatically (ensure_stack.py logic: Docker engine + `docker compose
    up -d`) and the request is retried once — only when talking to the LOCAL
    stack, never for a remote FIRECRAWL_API_URL,
  * transient HTTP statuses (429 / 5xx) are retried with a short backoff,
  * every failure is reported as an FcError with a clear, actionable message.

Endpoints: the base URL defaults to the local Firecrawl instance (port from
FIRECRAWL_PORT in the install folder's .env, default 9991). Two settings —
the same names the official firecrawl-mcp server uses — override it. Each
is read from the process environment FIRST, then from the install folder's
.env (where install-local-search persists the credentials when you answer
'y' to its "Add a Firecrawl account?" question):

  FIRECRAWL_API_URL    base URL of a Firecrawl API (e.g. the cloud API,
                       https://api.firecrawl.dev). Set this to use account
                       features (agent, interact, parse, monitors, research,
                       developer search) that the self-hosted instance does
                       not expose.
  FIRECRAWL_API_KEY    sent as `Authorization: Bearer <key>` when set —
                       required by the cloud API and account features.

Usage from a sibling script:

    import firecrawl_api as fc
    data = fc.call("/v1/map", method="POST", body={"url": url})

`call()` returns the parsed JSON response as a dict and raises FcError on
any failure (after the retries described above).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so error messages and progress output containing
# non-ASCII text never crash with a UnicodeEncodeError. Skipped if
# PYTHONIOENCODING is already set — an explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

# Default timeout per HTTP attempt (seconds); callers can override.
TIMEOUT = 90

# Transient statuses worth retrying: rate limit + common server errors.
RETRY_STATUSES = (429, 500, 502, 503, 504)
# Backoff before each retry (seconds): one entry per retry.
RETRY_BACKOFF = (1, 3)

# Cached view of the install folder's .env (lazily computed once: resolving
# the install folder may query Docker). Holds the FIRECRAWL_API_URL /
# FIRECRAWL_API_KEY values the installer wrote when a Firecrawl account was
# configured at install time.
_INSTALL_ENV = None


def _install_env():
    """The install folder's .env as a dict (see config.load_env), cached."""
    global _INSTALL_ENV
    if _INSTALL_ENV is None:
        try:
            _INSTALL_ENV = config.load_env(config.find_install_dir())
        except Exception:
            _INSTALL_ENV = {}
    return _INSTALL_ENV


def _setting(name):
    """Value of FIRECRAWL_API_URL / FIRECRAWL_API_KEY: the process
    environment first (the same override the official firecrawl-mcp server
    honours), then the install folder's .env. Stripped, possibly empty."""
    val = (os.environ.get(name) or "").strip()
    if val:
        return val
    return (_install_env().get(name) or "").strip()


class FcError(Exception):
    """A Firecrawl API failure after all retries, with a user-facing hint.

    Attributes:
        message  what went wrong (single line)
        status   HTTP status code, or None for connection/protocol errors
        hint     optional extra guidance printed by the CLI scripts
    """

    def __init__(self, message, status=None, hint=None):
        super().__init__(message)
        self.status = status
        self.hint = hint


def base_url():
    """The Firecrawl base URL: FIRECRAWL_API_URL when set in the environment
    or the install folder's .env (self-hosted remote or the cloud API),
    otherwise the local stack's endpoint (FIRECRAWL_PORT from the install
    folder's .env, default 9991)."""
    override = _setting("FIRECRAWL_API_URL")
    if override:
        return override.rstrip("/")
    return config.endpoints(config.find_install_dir())["firecrawl"]


def is_local():
    """True when requests go to the LOCAL stack (no FIRECRAWL_API_URL in the
    environment or the install folder's .env), i.e. self-healing a down
    stack can help."""
    return not _setting("FIRECRAWL_API_URL")


def url(path):
    """Absolute URL for an API path like '/v1/map' (see base_url())."""
    return base_url() + path


def auth_headers():
    """Headers for a JSON request: content type + optional Bearer auth from
    FIRECRAWL_API_KEY (environment or install .env; needed for account
    features / the cloud API)."""
    headers = {"Content-Type": "application/json"}
    key = _setting("FIRECRAWL_API_KEY")
    if key:
        headers["Authorization"] = "Bearer " + key
    return headers


def _selfheal():
    """Start the Docker engine + the containers if they are down (the same
    logic as ensure_stack.py). Import is deferred so the fast path (stack
    already up) pays nothing. Returns (ok, message)."""
    try:
        import ensure_stack
        ok, message, _code = ensure_stack.ensure_ready()
        return ok, message
    except Exception as e:  # unexpected self-heal failure: degrade gracefully
        return False, "self-heal failed unexpectedly: {}".format(e)


def _read_body(e):
    """Best-effort error body from an HTTPError (JSON message or raw text)."""
    try:
        raw = e.read()
    except Exception:
        return ""
    text = raw.decode("utf-8", "replace")[:800]
    try:
        payload = json.loads(text)
        msg = payload.get("error") or payload.get("message")
        if isinstance(msg, str) and msg:
            return msg
    except Exception:
        pass
    return text


def _hint_for_status(status):
    """Actionable guidance for the statuses account-gated endpoints return."""
    if status in (401, 403):
        return ("This tool needs an authenticated Firecrawl account: set "
                "FIRECRAWL_API_KEY (and FIRECRAWL_API_URL=https://api.firecrawl.dev "
                "to use the cloud API) and retry.")
    if status == 404:
        return ("This endpoint is not available on the Firecrawl instance it "
                "was called against. Account tools (monitor / research / "
                "developer search) need the cloud API: set "
                "FIRECRAWL_API_URL=https://api.firecrawl.dev and "
                "FIRECRAWL_API_KEY, then retry.")
    if status in RETRY_STATUSES:
        return ("The Firecrawl service answered with a server error. Wait a "
                "moment and retry; if it persists, inspect the stack with: "
                "cd <install folder> && docker compose logs --tail 50 firecrawl")
    return None


def _request(endpoint, method, body_bytes, headers, timeout):
    """One raw HTTP attempt. Raises HTTPError (service answered with an
    error status — service is UP) or URLError-family (connection problem —
    service is DOWN). Returns the parsed JSON response."""
    req = urllib.request.Request(endpoint, data=body_bytes,
                                 headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        text = r.read().decode("utf-8", "replace")
    if not text.strip():
        return {}
    try:
        return json.loads(text)
    except ValueError:
        raise FcError("Firecrawl returned a non-JSON response: "
                      + text[:300])


def call(path, method="GET", body=None, query=None, timeout=TIMEOUT):
    """Call the Firecrawl API with retries + self-healing.

    path    API path, e.g. "/v1/map" or "/v1/crawl/<id>" (already encoded)
    method  HTTP method (GET / POST / PATCH / DELETE)
    body    JSON-serialisable request body (dict) or None
    query   dict of query-string parameters (skipped when empty/None)
    timeout seconds per HTTP attempt

    Returns the parsed JSON response (dict). Raises FcError after the
    retries are exhausted (see module docstring for the retry policy)."""
    endpoint = url(path)
    if query:
        pairs = [(k, v) for k, v in query.items() if v is not None]
        if pairs:
            endpoint += "?" + urllib.parse.urlencode(pairs)
    body_bytes = None
    headers = auth_headers()
    if body is not None:
        body_bytes = json.dumps(body).encode("utf-8")

    attempts = 1 + len(RETRY_BACKOFF)  # initial + retries
    for attempt in range(1, attempts + 1):
        # ---- one attempt, classifying every failure mode -----------------
        try:
            return _request(endpoint, method, body_bytes, headers, timeout)
        except urllib.error.HTTPError as e:
            status = e.code
            detail = _read_body(e)
            if status in RETRY_STATUSES and attempt < attempts:
                wait = RETRY_BACKOFF[attempt - 1]
                print(f"Firecrawl answered {status} ({detail or 'server error'}) "
                      f"— retrying in {wait}s ...", file=sys.stderr)
                time.sleep(wait)
                continue
            raise FcError("HTTP {}{}{}".format(
                status, ": " + detail if detail else "",
                "" if attempt == 1 else f" (after {attempt} attempts)"),
                status=status, hint=_hint_for_status(status)) from e
        except FcError:
            raise
        except Exception as e:  # URLError / ConnectionError / timeout: DOWN
            if not is_local():
                raise FcError(
                    "could not reach {} ({}). Check the URL and your "
                    "network, then retry.".format(base_url(), e)) from e
            if attempt < attempts:
                # Local stack: try to bring it up, then retry the request.
                print(f"Stack unreachable ({e}) — starting it automatically ...",
                      file=sys.stderr)
                ok, message = _selfheal()
                if not ok:
                    raise FcError(
                        "the local-search stack could not be started: " + message
                        + " Resolve the stack (or ask the user to start Docker "
                          "Desktop) and retry — do NOT fall back to other web "
                          "tools unless the user asks.") from e
                continue
            raise FcError(
                "request failed after the stack was started: {}".format(e)) from e
    # unreachable: the loop either returns or raises
    raise FcError("request failed unexpectedly")


def call_form(path, fields, file_path, file_field="file", timeout=TIMEOUT):
    """Call the Firecrawl API with a multipart/form-data body (used by
    web_parse.py to upload a local document).

    fields      dict of form fields (values are str / int / list)
    file_path   the file to upload (read in binary mode)
    file_field  the form field name for the file (Firecrawl: "file")
    """
    boundary = "----localwebsearch" + format(int(time.time() * 1000), "x")
    parts = []
    for key, val in (fields or {}).items():
        if val is None:
            continue
        values = val if isinstance(val, list) else [val]
        for v in values:
            parts.append(("--" + boundary).encode("utf-8"))
            parts.append(('Content-Disposition: form-data; name="{}"'
                          .format(key)).encode("utf-8"))
            parts.append(b"")
            parts.append(str(v).encode("utf-8"))
    try:
        with open(file_path, "rb") as fh:
            payload = fh.read()
    except OSError as e:
        raise FcError("could not read {}: {}".format(file_path, e))
    filename = os.path.basename(file_path)
    parts.append(("--" + boundary).encode("utf-8"))
    parts.append(('Content-Disposition: form-data; name="{}"; filename="{}"'
                  .format(file_field, filename)).encode("utf-8"))
    parts.append(b"Content-Type: application/octet-stream")
    parts.append(b"")
    parts.append(payload)
    parts.append(("--" + boundary + "--").encode("utf-8"))
    body = b"\r\n".join(parts)

    endpoint = url(path)
    headers = {
        "Content-Type": "multipart/form-data; boundary=" + boundary,
    }
    key = _setting("FIRECRAWL_API_KEY")
    if key:
        headers["Authorization"] = "Bearer " + key

    try:
        return _request(endpoint, "POST", body, headers, timeout)
    except urllib.error.HTTPError as e:
        status = e.code
        detail = _read_body(e)
        raise FcError("HTTP {}{}{}".format(
            status, ": " + detail if detail else ""),
            status=status, hint=_hint_for_status(status)) from e
    except FcError:
        raise
    except Exception as e:  # connection problem: stack (probably) down
        if not is_local():
            raise FcError(
                "could not reach {} ({}). Check the URL and your network, "
                "then retry.".format(base_url(), e)) from e
        print(f"Stack unreachable ({e}) — starting it automatically ...",
              file=sys.stderr)
        ok, message = _selfheal()
        if not ok:
            raise FcError("the local-search stack could not be started: "
                          + message) from e
        try:
            return _request(endpoint, "POST", body, headers, timeout)
        except urllib.error.HTTPError as e2:
            raise FcError("HTTP {}: {}".format(e2.code, _read_body(e2)),
                          status=e2.code,
                          hint=_hint_for_status(e2.code)) from e2
        except Exception as e2:
            raise FcError("request failed after the stack was started: "
                          "{}".format(e2)) from e2
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_FIRECRAWL_API_PY

# --- local-search/local-web-search/scripts/web_search.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_search.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SEARCH_PY'
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
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SEARCH_PY

# --- local-search/local-web-search/scripts/web_scrape.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_scrape.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SCRAPE_PY'
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
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SCRAPE_PY

# --- local-search/local-web-search/scripts/web_map.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_map.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MAP_PY'
#!/usr/bin/env python3
"""Map a website: enumerate the URLs Firecrawl indexes under it, without
fetching each page's content (the firecrawl_map MCP tool).

Usage:
    python web_map.py <url> [--search term] [--limit N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

`--search` filters/boosts URLs containing the term (server-side). Prints up
to `limit` URLs (default 100), one per line, numbered. `--json` prints the
raw API response instead.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/map")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_map.py <url> [--search term] [--limit N] [--json]",
              file=sys.stderr)
        return 2
    url = args[0]
    search, limit, as_json = None, 100, False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--search" and i + 1 < len(args):
            i += 1
            search = args[i]
        elif a == "--limit" and i + 1 < len(args):
            i += 1
            try:
                limit = int(args[i])
            except ValueError:
                print(f"invalid --limit: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            print(f"unexpected argument: {a}", file=sys.stderr)
            return 2
        i += 1

    body = {"url": url}
    if search:
        body["search"] = search

    try:
        data = fc.call("/v1/map", method="POST", body=body)
    except fc.FcError as e:
        print(f"MAP FAILED for {url}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    links = data.get("links")
    if links is None:
        payload = data.get("data")
        if isinstance(payload, dict):
            links = payload.get("links")
    if not isinstance(links, list):
        links = []
    if not links:
        print("(no URLs found)")
        return 0
    for n, link in enumerate(links[:limit], 1):
        print(f"{n}. {link}")
    if len(links) > limit:
        print(f"[... {len(links) - limit} more URLs; raise --limit or use --json ...]",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MAP_PY

# --- local-search/local-web-search/scripts/web_crawl.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_crawl.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_CRAWL_PY'
#!/usr/bin/env python3
"""Run a site crawl: start a multi-page Firecrawl crawl at a URL, poll it to
a terminal state, and report the final status and collected data (the
firecrawl_crawl MCP tool).

Usage:
    python web_crawl.py <url> [--prompt text] [--timeout S] [--poll-interval S]
                        [--max-pages N] [--max-chars N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Polls the crawl every --poll-interval seconds (default 2) until it reaches a
terminal state (completed / failed / cancelled) or --timeout seconds elapse
(default 300). Progress is printed to stderr. When the crawl completes, each
collected page prints as `N. <url>` followed by its markdown truncated at
--max-chars chars (default 2000; up to --max-pages pages, default 25).
`--json` prints the final status response instead.

If the crawl has not finished within --timeout, the crawl ID and current
progress are printed — keep polling with web_crawl_status.py <id>.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/crawl")

# Crawl-job states that mean "no more polling".
TERMINAL = ("completed", "failed", "cancelled", "stopped")


def crawl_summary(data):
    """One-line status summary from a crawl-status payload."""
    status = data.get("status") or "unknown"
    completed = data.get("completed")
    total = data.get("total")
    if completed is not None and total is not None:
        return f"{status} ({completed}/{total} pages)"
    return str(status)


def print_pages(data, max_pages, max_chars):
    """Print the collected pages: `N. <url>` + truncated markdown."""
    pages = data.get("data")
    if not isinstance(pages, list) or not pages:
        return
    shown = pages[:max_pages]
    for n, page in enumerate(shown, 1):
        if not isinstance(page, dict):
            continue
        print(f"{n}. {page.get('url') or page.get('sourceURL') or '(no url)'}")
        markdown = page.get("markdown") or ""
        if markdown:
            if len(markdown) > max_chars:
                markdown = markdown[:max_chars] \
                    + f"\n   [... truncated at {max_chars} chars ...]"
            for line in markdown.splitlines() or [""]:
                print(f"   {line}")
    if len(pages) > max_pages:
        print(f"[... {len(pages) - max_pages} more pages; raise --max-pages "
              f"or use --json ...]", file=sys.stderr)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_crawl.py <url> [--prompt text] [--timeout S] "
              "[--poll-interval S] [--max-pages N] [--max-chars N] [--json]",
              file=sys.stderr)
        return 2
    url = args[0]
    prompt = None
    timeout, poll_every = 300, 2
    max_pages, max_chars, as_json = 25, 2000, False
    i = 1

    def num(name):
        # `i` already points at the option's value (the branch incremented it).
        try:
            return int(args[i])
        except (ValueError, IndexError):
            print(f"invalid {name}: {args[i] if i < len(args) else ''}",
                  file=sys.stderr)
            sys.exit(2)

    while i < len(args):
        a = args[i]
        if a == "--prompt" and i + 1 < len(args):
            i += 1
            prompt = args[i]
        elif a == "--timeout" and i + 1 < len(args):
            i += 1
            timeout = num("--timeout")
        elif a == "--poll-interval" and i + 1 < len(args):
            i += 1
            poll_every = num("--poll-interval")
        elif a == "--max-pages" and i + 1 < len(args):
            i += 1
            max_pages = num("--max-pages")
        elif a == "--max-chars" and i + 1 < len(args):
            i += 1
            max_chars = num("--max-chars")
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            print(f"unexpected argument: {a}", file=sys.stderr)
            return 2
        i += 1

    body = {"url": url}
    if prompt:
        body["prompt"] = prompt

    # ---- start the crawl ------------------------------------------------
    try:
        started = fc.call("/v1/crawl", method="POST", body=body)
    except fc.FcError as e:
        print(f"CRAWL FAILED for {url}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1
    crawl_id = started.get("id") or (started.get("data") or {}).get("id")
    if not crawl_id:
        print("CRAWL FAILED for {}: the API did not return a crawl id. "
              "Response:".format(url), file=sys.stderr)
        print(json.dumps(started)[:800], file=sys.stderr)
        return 1
    print(f"Crawl started: {crawl_id}", file=sys.stderr)

    # ---- poll to a terminal state ---------------------------------------
    deadline = time.time() + timeout
    while True:
        try:
            data = fc.call("/v1/crawl/" + str(crawl_id), method="GET")
        except fc.FcError as e:
            print(f"CRAWL FAILED for {url}: status check failed: {e}",
                  file=sys.stderr)
            if e.hint:
                print(e.hint, file=sys.stderr)
            return 1
        status = str(data.get("status") or "unknown")
        if status in TERMINAL or (status not in
                                  ("active", "scraping", "queued", "processing",
                                   "waiting", "running") and data.get("data")):
            break
        if time.time() >= deadline:
            print(f"Crawl {crawl_id} still {crawl_summary(data)} after "
                  f"{timeout}s — keeping polling with:", file=sys.stderr)
            print(f"    python web_crawl_status.py {crawl_id}", file=sys.stderr)
            if as_json:
                print(json.dumps(data))
            else:
                print(f"Crawl {crawl_id}: {crawl_summary(data)} (timed out)")
            return 1
        print(f"  crawl {crawl_id}: {crawl_summary(data)}", file=sys.stderr)
        time.sleep(max(poll_every, 1))

    if as_json:
        print(json.dumps(data))
        return 0 if status == "completed" else 1

    if status != "completed":
        print(f"CRAWL FAILED for {url}: crawl {crawl_id} ended as "
              f"\"{status}\".", file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1

    credits = data.get("creditsUsed")
    suffix = f", {credits} credits used" if credits is not None else ""
    print(f"Crawl {crawl_id}: {crawl_summary(data)}{suffix}")
    print_pages(data, max_pages, max_chars)
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_CRAWL_PY

# --- local-search/local-web-search/scripts/web_crawl_status.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_crawl_status.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_CRAWL_STATUS_PY'
#!/usr/bin/env python3
"""Get the status, progress, and available results of an existing Firecrawl
crawl (the firecrawl_check_crawl_status MCP tool).

Usage:
    python web_crawl_status.py <id> [--max-pages N] [--max-chars N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints `Crawl <id>: <status> (completed/total pages)`; when the crawl has
finished, the collected pages follow as `N. <url>` + markdown truncated at
--max-chars chars (default 2000; up to --max-pages pages, default 25).
`--json` prints the raw API response instead. The status query itself only
fails (exit 1) when the API cannot be reached; a `failed` crawl still exits 0.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal
import web_crawl  # sibling: shared crawl output formatting

ENDPOINT = fc.url("/v1/crawl")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_crawl_status.py <id> [--max-pages N] [--max-chars N] "
              "[--json]", file=sys.stderr)
        return 2
    crawl_id = args[0]
    max_pages, max_chars, as_json = 25, 2000, False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--max-pages" and i + 1 < len(args):
            i += 1
            try:
                max_pages = int(args[i])
            except ValueError:
                print(f"invalid --max-pages: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--max-chars" and i + 1 < len(args):
            i += 1
            try:
                max_chars = int(args[i])
            except ValueError:
                print(f"invalid --max-chars: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            print(f"unexpected argument: {a}", file=sys.stderr)
            return 2
        i += 1

    try:
        data = fc.call("/v1/crawl/" + str(crawl_id), method="GET")
    except fc.FcError as e:
        print(f"CRAWL STATUS FAILED for {crawl_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    print(f"Crawl {crawl_id}: {web_crawl.crawl_summary(data)}")
    web_crawl.print_pages(data, max_pages, max_chars)
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_CRAWL_STATUS_PY

# --- local-search/local-web-search/scripts/web_agent.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_agent.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_AGENT_PY'
#!/usr/bin/env python3
"""Start an asynchronous Firecrawl research agent job (the firecrawl_agent
MCP tool): give it a prompt, optional seed URLs, and read the result later
with web_agent_status.py.

Usage:
    python web_agent.py "<prompt>" [seed_url ...] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

The first argument is the research prompt (quote it); any further positional
arguments are seed URLs the agent should start from. This call only STARTS
the job and prints its ID — the research itself commonly takes several
minutes, so poll the job until it is completed or failed:

    python web_agent_status.py <id>

`--json` prints the raw API response instead of the summary.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/agent")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print('usage: web_agent.py "<prompt>" [seed_url ...] [--json]',
              file=sys.stderr)
        return 2
    prompt = args[0]
    urls, as_json = [], False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            urls.append(a)
        i += 1

    body = {"prompt": prompt}
    if urls:
        body["urls"] = urls

    try:
        data = fc.call("/v1/agent", method="POST", body=body)
    except fc.FcError as e:
        print(f"AGENT START FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    job_id = payload.get("id") or data.get("id")
    if not job_id:
        print("AGENT START FAILED: the API did not return a job id. Response:",
              file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1
    print(f"Agent job started: {job_id}")
    if urls:
        print(f"Seed URLs: {', '.join(urls)}")
    print("Research commonly takes several minutes — poll with:")
    print(f"    python web_agent_status.py {job_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_AGENT_PY

# --- local-search/local-web-search/scripts/web_agent_status.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_agent_status.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_AGENT_STATUS_PY'
#!/usr/bin/env python3
"""Get the progress or final results of a Firecrawl research agent job (the
firecrawl_agent_status MCP tool), started with web_agent.py.

Usage:
    python web_agent_status.py <id> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints `Agent <id>: <status>`. A `processing`/`active` status is non-terminal
— check again after 15-30 s. When the job is `completed`, the research result
follows (steps, sources, and the final answer/report as returned by the API);
`failed` jobs print the available error details and exit 1. `--json` prints
the raw API response instead.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/agent")


def print_result(result, indent=0):
    """Recursively print the agent result in a readable outline."""
    pad = " " * indent
    if isinstance(result, dict):
        for key, val in result.items():
            if isinstance(val, (dict, list)):
                print(f"{pad}{key}:")
                print_result(val, indent + 2)
            else:
                text = str(val)
                if len(text) > 4000:
                    text = text[:4000] + f"\n{pad}[... truncated ...]"
                print(f"{pad}{key}: {text}")
    elif isinstance(result, list):
        for n, item in enumerate(result, 1):
            print(f"{pad}{n}.")
            print_result(item, indent + 2)
    else:
        text = str(result)
        if len(text) > 4000:
            text = text[:4000] + f"\n{pad}[... truncated ...]"
        print(pad + text)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_agent_status.py <id> [--json]", file=sys.stderr)
        return 2
    job_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/agent/" + str(job_id), method="GET")
    except fc.FcError as e:
        print(f"AGENT STATUS FAILED for {job_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0 if data.get("status") != "failed" else 1

    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    status = str(payload.get("status") or data.get("status") or "unknown")
    print(f"Agent {job_id}: {status}")
    if status not in ("completed", "failed", "cancelled", "stopped"):
        print("(non-terminal — check again after 15-30 s)")
        return 0
    result = payload.get("result")
    if result is None:
        result = data.get("result")
    if result is not None:
        print()
        print_result(result)
    elif status == "failed":
        error = payload.get("error") or data.get("error")
        print(f"error: {error or '(no details returned)'}")
    return 0 if status == "completed" else 1


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_AGENT_STATUS_PY

# --- local-search/local-web-search/scripts/web_interact.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_interact.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_INTERACT_PY'
#!/usr/bin/env python3
"""Interact with a scraped page through a live Firecrawl browser session
(the firecrawl_interact MCP tool): navigate, click controls, fill fields, or
run browser code.

Usage:
    python web_interact.py (--scrape-id ID | --url URL)
                           (--prompt TEXT | --code TEXT [--language bash|python|node])
                           [--timeout S] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Provide EITHER --scrape-id (reuse a previous scrape's session) or --url
(open a fresh session), and EITHER --prompt (natural-language instructions)
or --code (with --language, default bash). NOTE: this acts on the LIVE site —
actions such as form submission can create persistent external side effects.

Prints the API's JSON response: execution output, stdout/stderr, exit
status, and the session viewing URLs. `--json` prints it compact on one line
instead of pretty-printed.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/interact")

LANGUAGES = ("bash", "python", "node")


def main() -> int:
    args = sys.argv[1:]
    scrape_id, url = None, None
    prompt, code, language = None, None, None
    timeout, as_json = None, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--scrape-id" and i + 1 < len(args):
            i += 1
            scrape_id = args[i]
        elif a == "--url" and i + 1 < len(args):
            i += 1
            url = args[i]
        elif a == "--prompt" and i + 1 < len(args):
            i += 1
            prompt = args[i]
        elif a == "--code" and i + 1 < len(args):
            i += 1
            code = args[i]
        elif a == "--language" and i + 1 < len(args):
            i += 1
            language = args[i]
            if language not in LANGUAGES:
                print(f"invalid --language: {language} "
                      f"(one of {', '.join(LANGUAGES)})", file=sys.stderr)
                return 2
        elif a == "--timeout" and i + 1 < len(args):
            i += 1
            try:
                timeout = int(args[i])
            except ValueError:
                print(f"invalid --timeout: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            print(f"unexpected argument: {a}", file=sys.stderr)
            return 2
        i += 1

    if bool(scrape_id) == bool(url):
        print("provide exactly one of --scrape-id (reuse a scrape's session) "
              "or --url (open a new session), not both", file=sys.stderr)
        return 2
    if not prompt and not code:
        print("provide either --prompt (natural language) or --code "
              "(executable, with --language)", file=sys.stderr)
        return 2
    if language and not code:
        print("--language can only be used together with --code",
              file=sys.stderr)
        return 2

    body = {}
    if scrape_id:
        body["scrapeId"] = scrape_id
    else:
        body["url"] = url
    if prompt:
        body["prompt"] = prompt
    if code:
        body["code"] = code
        body["language"] = language or "bash"
    if timeout is not None:
        body["timeout"] = timeout

    try:
        data = fc.call("/v1/interact", method="POST", body=body)
    except fc.FcError as e:
        print(f"INTERACT FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    print(json.dumps(data) if as_json else json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_INTERACT_PY

# --- local-search/local-web-search/scripts/web_interact_stop.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_interact_stop.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_INTERACT_STOP_PY'
#!/usr/bin/env python3
"""Stop the live Firecrawl interact session for a scrapeId and release its
resources (the firecrawl_interact_stop MCP tool).

Usage:
    python web_interact_stop.py <scrapeId> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints a confirmation (plus the API's response body when one is returned).
`--json` prints the raw API response instead. The session cannot be resumed
after it is stopped.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/interact")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_interact_stop.py <scrapeId> [--json]", file=sys.stderr)
        return 2
    scrape_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/interact/" + str(scrape_id) + "/stop",
                       method="POST")
    except fc.FcError as e:
        print(f"INTERACT STOP FAILED for {scrape_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(f"Interact session {scrape_id} stopped.")
    if data:
        print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_INTERACT_STOP_PY

# --- local-search/local-web-search/scripts/web_parse.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_parse.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_PARSE_PY'
#!/usr/bin/env python3
"""Parse a local document into markdown / HTML / links / a summary / targeted
answers / structured JSON (the firecrawl_parse MCP tool). Supported inputs
include common HTML, PDF, Word, RTF, OpenDocument, and spreadsheet files.

Usage:
    python web_parse.py <filePath> [--formats markdown,links,...] [--max-chars N]
                        [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once. You do NOT need to run ensure_stack.py first — just run the
script.

The file is uploaded to the local Firecrawl instance (it never leaves your
machine). `--formats` takes a comma-separated list from: markdown, html,
rawHtml, links, summary, json, query (default: markdown). Prints the parsed
content; with several formats each is printed under a `## <format>` header.
Markdown/HTML truncate at --max-chars chars (default 20000, like
web_scrape.py). `--json` prints the raw API response instead.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/parse")

FORMATS = ("markdown", "html", "rawHtml", "links", "summary", "json", "query")

# Extension -> MIME type for the upload (everything else is sent as a
# generic octet stream and Firecrawl sniffs the real type server-side).
MIME_TYPES = {
    ".html": "text/html", ".htm": "text/html",
    ".pdf": "application/pdf",
    ".doc": "application/msword",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".rtf": "application/rtf",
    ".odt": "application/vnd.oasis.opendocument.text",
    ".ods": "application/vnd.oasis.opendocument.spreadsheet",
    ".xls": "application/vnd.ms-excel",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".csv": "text/csv",
    ".txt": "text/plain",
    ".md": "text/markdown",
}

# Formats whose content is plain text and can be truncated safely.
TEXT_FORMATS = ("markdown", "html", "rawHtml", "summary", "query")


def content_type_for(path):
    return MIME_TYPES.get(os.path.splitext(path)[1].lower(),
                          "application/octet-stream")


def print_field(name, value, max_chars):
    """Print one parsed format under a header, truncating long text."""
    if name != "markdown":
        print(f"## {name}")
    if isinstance(value, list):
        for n, item in enumerate(value, 1):
            print(f"{n}. {item}")
        return
    if isinstance(value, (dict, bool, int, float)):
        print(json.dumps(value, indent=2))
        return
    text = str(value)
    if not text:
        print("(empty)")
        return
    if name in TEXT_FORMATS and len(text) > max_chars:
        text = text[:max_chars] + f"\n[... truncated at {max_chars} chars ...]"
    print(text)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_parse.py <filePath> [--formats markdown,links,...] "
              "[--max-chars N] [--json]", file=sys.stderr)
        return 2
    file_path = args[0]
    formats = ["markdown"]
    max_chars, as_json = 20000, False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--formats" and i + 1 < len(args):
            i += 1
            formats = [f.strip() for f in args[i].split(",") if f.strip()]
            bad = [f for f in formats if f not in FORMATS]
            if bad:
                print(f"invalid --formats value(s): {', '.join(bad)} "
                      f"(valid: {', '.join(FORMATS)})", file=sys.stderr)
                return 2
        elif a == "--max-chars" and i + 1 < len(args):
            i += 1
            try:
                max_chars = int(args[i])
            except ValueError:
                print(f"invalid --max-chars: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            print(f"unexpected argument: {a}", file=sys.stderr)
            return 2
        i += 1

    if not os.path.isfile(file_path):
        print(f"PARSE FAILED: no such file: {file_path}", file=sys.stderr)
        return 1

    options = {"formats": formats}
    fields = {"options": json.dumps(options),
              "contentType": content_type_for(file_path)}
    try:
        data = fc.call_form("/v1/parse", fields, file_path)
    except fc.FcError as e:
        print(f"PARSE FAILED for {file_path}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    printed = 0
    for fmt in formats:
        value = payload.get(fmt)
        if value is None:
            continue
        if printed:
            print()
        print_field(fmt, value, max_chars)
        printed += 1
    if not printed:
        print(f"PARSE RETURNED NO CONTENT for {file_path}", file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_PARSE_PY

# --- local-search/local-web-search/scripts/web_monitor_create.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_monitor_create.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CREATE_PY'
#!/usr/bin/env python3
"""Create a recurring Firecrawl monitor — a scrape, crawl, or search check
that compares each run with its retained predecessor (the
firecrawl_monitor_create MCP tool).

Usage:
    python web_monitor_create.py (--body '{...}' | --body-file monitor.json)
                                 [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

`--body` is the full monitor configuration as JSON (same object the MCP
tool's `body` parameter takes: name, schedule, goal, targets, webhook,
notification, retention, ...). `--body-file` reads it from a file instead.
Prints the created monitor as pretty JSON; `--json` prints the raw API
response instead.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def read_body_arg(args):
    """Return the monitor body as a dict from --body / --body-file, or
    (None, error-message)."""
    body_raw, body_file = None, None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--body" and i + 1 < len(args):
            i += 1
            body_raw = args[i]
        elif a == "--body-file" and i + 1 < len(args):
            i += 1
            body_file = args[i]
        i += 1
    if body_raw is not None and body_file is not None:
        return None, "provide either --body or --body-file, not both"
    if body_file is not None:
        try:
            with open(body_file, encoding="utf-8") as fh:
                body_raw = fh.read()
        except OSError as e:
            return None, "could not read {}: {}".format(body_file, e)
    if body_raw is None:
        return None, ("a monitor body is required: --body '{...}' "
                      "(full monitor JSON) or --body-file FILE")
    try:
        body = json.loads(body_raw)
    except ValueError as e:
        return None, "the body is not valid JSON: {}".format(e)
    if not isinstance(body, dict):
        return None, "the monitor body must be a JSON object"
    return body, None


def main() -> int:
    args = sys.argv[1:]
    as_json = "--json" in args
    body, err = read_body_arg(args)
    if err:
        print("usage: web_monitor_create.py (--body '{...}' | "
              "--body-file monitor.json) [--json]", file=sys.stderr)
        print(err, file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/monitor", method="POST", body=body)
    except fc.FcError as e:
        print(f"MONITOR CREATE FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CREATE_PY

# --- local-search/local-web-search/scripts/web_monitor_list.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_monitor_list.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_LIST_PY'
#!/usr/bin/env python3
"""List the Firecrawl monitors of the authenticated account (the
firecrawl_monitor_list MCP tool), with optional pagination.

Usage:
    python web_monitor_list.py [--limit N] [--offset N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints one line per monitor: `N. <id> — <name> (<state>)`. `--json` prints
the raw API response instead.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = sys.argv[1:]
    limit, offset, as_json = None, None, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--limit" and i + 1 < len(args):
            i += 1
            try:
                limit = int(args[i])
            except ValueError:
                print(f"invalid --limit: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--offset" and i + 1 < len(args):
            i += 1
            try:
                offset = int(args[i])
            except ValueError:
                print(f"invalid --offset: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            print(f"unexpected argument: {a}", file=sys.stderr)
            return 2
        i += 1

    query = {}
    if limit is not None:
        query["limit"] = limit
    if offset is not None:
        query["offset"] = offset

    try:
        data = fc.call("/v1/monitor", method="GET", query=query)
    except fc.FcError as e:
        print(f"MONITOR LIST FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    monitors = data.get("monitors")
    if not isinstance(monitors, list):
        monitors = data.get("data")
    if not isinstance(monitors, list):
        monitors = data if isinstance(data, list) else []
    if not monitors:
        print("(no monitors)")
        return 0
    for n, monitor in enumerate(monitors, 1):
        if not isinstance(monitor, dict):
            print(f"{n}. {monitor}")
            continue
        mid = monitor.get("id") or monitor.get("monitorId") or "?"
        name = monitor.get("name") or "(unnamed)"
        state = (monitor.get("state") or monitor.get("status")
                 or ("active" if monitor.get("active") else "paused"))
        print(f"{n}. {mid} — {name} ({state})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_LIST_PY

# --- local-search/local-web-search/scripts/web_monitor_get.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_monitor_get.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_GET_PY'
#!/usr/bin/env python3
"""Retrieve one Firecrawl monitor by ID, including its configuration and
current state (the firecrawl_monitor_get MCP tool).

Usage:
    python web_monitor_get.py <id> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the monitor as pretty JSON. `--json` prints the raw API response
instead. This does not run or modify the monitor.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_monitor_get.py <id> [--json]", file=sys.stderr)
        return 2
    monitor_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id), method="GET")
    except fc.FcError as e:
        print(f"MONITOR GET FAILED for {monitor_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_GET_PY

# --- local-search/local-web-search/scripts/web_monitor_update.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_monitor_update.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_UPDATE_PY'
#!/usr/bin/env python3
"""Patch an existing Firecrawl monitor by ID (the firecrawl_monitor_update
MCP tool): change its name, active/paused status, schedule, targets, goal,
judging, webhook, notifications, or retention — these changes affect future
scheduled checks.

Usage:
    python web_monitor_update.py <id> (--body '{...}' | --body-file patch.json)
                                  [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

`--body` is the patch as JSON (same object the MCP tool's `body` parameter
takes); `--body-file` reads it from a file instead. Prints the updated
monitor as pretty JSON; `--json` prints the raw API response instead.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal
import web_monitor_create  # sibling: shared --body / --body-file reading

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_monitor_update.py <id> (--body '{...}' | "
              "--body-file patch.json) [--json]", file=sys.stderr)
        return 2
    monitor_id = args[0]
    as_json = "--json" in args
    body, err = web_monitor_create.read_body_arg(args)
    if err:
        print(err, file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id), method="PATCH",
                       body=body)
    except fc.FcError as e:
        print(f"MONITOR UPDATE FAILED for {monitor_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_UPDATE_PY

# --- local-search/local-web-search/scripts/web_monitor_delete.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_monitor_delete.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_DELETE_PY'
#!/usr/bin/env python3
"""Permanently delete a Firecrawl monitor by ID and stop its future schedule
(the firecrawl_monitor_delete MCP tool). This cannot be undone.

Usage:
    python web_monitor_delete.py <id> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints a confirmation (plus the API's response body when one is returned).
`--json` prints the raw API response instead.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_monitor_delete.py <id> [--json]", file=sys.stderr)
        return 2
    monitor_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id), method="DELETE")
    except fc.FcError as e:
        print(f"MONITOR DELETE FAILED for {monitor_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(f"Monitor {monitor_id} deleted.")
    if data:
        print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_DELETE_PY

# --- local-search/local-web-search/scripts/web_monitor_run.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_monitor_run.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_RUN_PY'
#!/usr/bin/env python3
"""Queue an immediate check for a Firecrawl monitor, outside its normal
schedule (the firecrawl_monitor_run MCP tool).

Usage:
    python web_monitor_run.py <id> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the queued check as pretty JSON. `--json` prints the raw API response
instead. Follow the check with web_monitor_checks.py / web_monitor_check.py.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_monitor_run.py <id> [--json]", file=sys.stderr)
        return 2
    monitor_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id) + "/run",
                       method="POST")
    except fc.FcError as e:
        print(f"MONITOR RUN FAILED for {monitor_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_RUN_PY

# --- local-search/local-web-search/scripts/web_monitor_checks.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_monitor_checks.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CHECKS_PY'
#!/usr/bin/env python3
"""List the historical checks of a Firecrawl monitor (the
firecrawl_monitor_checks MCP tool), optionally filtered by status and
paginated.

Usage:
    python web_monitor_checks.py <id> [--status queued|running|completed|failed|partial]
                                 [--limit N] [--offset N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints one line per check: `N. <checkId> <status> <createdAt>`. `--json`
prints the raw API response instead. Read one check's page-level results
with web_monitor_check.py.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")

STATUSES = ("queued", "running", "completed", "failed", "partial")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_monitor_checks.py <id> "
              "[--status queued|running|completed|failed|partial] "
              "[--limit N] [--offset N] [--json]", file=sys.stderr)
        return 2
    monitor_id = args[0]
    status, limit, offset, as_json = None, None, None, False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--status" and i + 1 < len(args):
            i += 1
            status = args[i]
            if status not in STATUSES:
                print(f"invalid --status: {status} "
                      f"(one of {', '.join(STATUSES)})", file=sys.stderr)
                return 2
        elif a == "--limit" and i + 1 < len(args):
            i += 1
            try:
                limit = int(args[i])
            except ValueError:
                print(f"invalid --limit: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--offset" and i + 1 < len(args):
            i += 1
            try:
                offset = int(args[i])
            except ValueError:
                print(f"invalid --offset: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            print(f"unexpected argument: {a}", file=sys.stderr)
            return 2
        i += 1

    query = {}
    if status is not None:
        query["status"] = status
    if limit is not None:
        query["limit"] = limit
    if offset is not None:
        query["offset"] = offset

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id) + "/checks",
                       method="GET", query=query)
    except fc.FcError as e:
        print(f"MONITOR CHECKS FAILED for {monitor_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    checks = data.get("checks")
    if not isinstance(checks, list):
        checks = data.get("data")
    if not isinstance(checks, list):
        checks = data if isinstance(data, list) else []
    if not checks:
        print("(no checks)")
        return 0
    for n, check in enumerate(checks, 1):
        if not isinstance(check, dict):
            print(f"{n}. {check}")
            continue
        cid = check.get("id") or check.get("checkId") or "?"
        cstatus = check.get("status") or "?"
        when = (check.get("createdAt") or check.get("startedAt")
                or check.get("completedAt") or "")
        print(f"{n}. {cid} {cstatus} {when}".rstrip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CHECKS_PY

# --- local-search/local-web-search/scripts/web_monitor_check.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_monitor_check.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CHECK_PY'
#!/usr/bin/env python3
"""Retrieve one Firecrawl monitor check and its page-level results (the
firecrawl_monitor_check MCP tool). Pages report `same`, `new`, `changed`,
`removed`, or `error`; goal judging adds a meaningful-change decision.
Markdown tracking returns a unified text diff; JSON tracking returns field
paths with previous/current values.

Usage:
    python web_monitor_check.py <id> <checkId> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the check (configuration, page results, diffs) as pretty JSON.
`--json` prints the raw API response instead.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    if len(args) != 2 or args[0].startswith("--") or args[1].startswith("--"):
        print("usage: web_monitor_check.py <id> <checkId> [--json]",
              file=sys.stderr)
        return 2
    monitor_id, check_id = args

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id) + "/checks/"
                       + str(check_id), method="GET")
    except fc.FcError as e:
        print(f"MONITOR CHECK FAILED for {monitor_id}/{check_id}: {e}",
              file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CHECK_PY

# --- local-search/local-web-search/scripts/web_research_search.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_research_search.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_SEARCH_PY'
#!/usr/bin/env python3
"""Search research papers via the Firecrawl research index (the
firecrawl_research_search_papers MCP tool): paper metadata and abstracts
across biomedical, life-science, and clinical literature (PubMed, bioRxiv,
medRxiv) alongside arXiv and other scientific sources.

Usage:
    python web_research_search.py "<query>" [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the ranked papers exactly like the MCP tool does — for each paper:

    ## [paperId] title
    Authors: name; name; +N more
    abstract (up to 600 chars)

Several distinct framings of the same question surface different papers.
Inspect one paper with web_research_inspect.py. `--json` prints the raw API
response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/research/search/papers")

MAX_AUTHORS = 15
MAX_ABSTRACT_CHARS = 600
MAX_AFFIL_CHARS = 60
MAX_AUTHORS_LINE_CHARS = 400


def display_id(paper):
    return paper.get("primaryId") or paper.get("paperId") or "missing-primary-id"


def fmt_authors(authors):
    """`Authors: a; b (affiliation); +N more` or None (mirrors the MCP tool)."""
    if not authors:
        return None
    if isinstance(authors, str):
        names = [s.strip() for s in authors.split(",") if s.strip()]
        if not names:
            return None
        total, shown = len(names), names[:MAX_AUTHORS]
    else:
        if not isinstance(authors, list) or not authors:
            return None
        total = len(authors)
        shown = []
        for a in authors[:MAX_AUTHORS]:
            if isinstance(a, dict):
                aff = (a.get("affiliation") or "").strip()
                name = a.get("name") or "?"
                shown.append("{} ({})".format(name, aff[:MAX_AFFIL_CHARS])
                             if aff else name)
            else:
                shown.append(str(a))
    extra = "; +{} more".format(total - MAX_AUTHORS) if total > MAX_AUTHORS \
        else ""
    return ("Authors: " + "; ".join(shown) + extra)[:MAX_AUTHORS_LINE_CHARS]


def fmt_hits(results):
    """Format ranked paper results (mirrors the MCP tool's formatter)."""
    if not results:
        return "(no results)"
    blocks = []
    for r in results:
        if not isinstance(r, dict):
            blocks.append(str(r))
            continue
        lines = ["## [{}] {}".format(display_id(r),
                                     r.get("title") or "(untitled)")]
        authors = fmt_authors(r.get("authors"))
        if authors:
            lines.append(authors)
        abstract = (r.get("abstract") or "(no abstract)")
        abstract = " ".join(abstract.split())[:MAX_ABSTRACT_CHARS]
        lines.append(abstract)
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def extract_results(data):
    """Find the paper-result list in the API response."""
    results = data.get("results")
    if isinstance(results, list):
        return results
    payload = data.get("data")
    if isinstance(payload, dict) and isinstance(payload.get("results"), list):
        return payload["results"]
    if isinstance(data, list):
        return data
    return []


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    query = " ".join(args).strip()
    if not query:
        print('usage: web_research_search.py "<query>" [--json]', file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/research/search/papers", method="POST",
                       body={"query": query})
    except fc.FcError as e:
        print(f"RESEARCH SEARCH FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(fmt_hits(extract_results(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_SEARCH_PY

# --- local-search/local-web-search/scripts/web_research_inspect.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_research_inspect.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_INSPECT_PY'
#!/usr/bin/env python3
"""Inspect one research paper via the Firecrawl research index (the
firecrawl_research_inspect_paper MCP tool): canonical metadata for a paper
ID such as an arXiv, PMC, PMID, or DOI identifier.

Usage:
    python web_research_inspect.py <paperId> [--json]

Examples:
    python web_research_inspect.py arxiv:1706.03762
    python web_research_inspect.py doi:10.1016/j.neunet.2025.108095

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the paper's metadata exactly like the MCP tool does:

    # title
    Paper ID: ...
    IDs: namespace:value, ...
    Authors: ...
    Categories: ...
    Dates: created ...; updated ...
    ## Abstract
    ...

Find papers to inspect with web_research_search.py. `--json` prints the raw
API response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal
import web_research_search  # sibling: shared paper formatters

ENDPOINT = fc.url("/v1/research/papers")


def fmt_paper_metadata(paper):
    """Format one paper's metadata (mirrors the MCP tool's formatter)."""
    if not paper:
        return "(paper not found)"
    lines = ["# " + (paper.get("title") or "(untitled)"), ""]
    lines.append("Paper ID: {}".format(paper.get("paperId") or "?"))
    ids = []
    for namespace, values in (paper.get("ids") or {}).items():
        if isinstance(values, list):
            ids.extend("{}:{}".format(namespace, v) for v in values)
        elif values is not None:
            ids.append("{}:{}".format(namespace, values))
    if ids:
        lines.append("IDs: " + ", ".join(ids))
    authors = web_research_search.fmt_authors(paper.get("authors"))
    if authors:
        lines.append(authors)
    categories = paper.get("categories")
    if isinstance(categories, list) and categories:
        lines.append("Categories: " + ", ".join(str(c) for c in categories))
    dates = []
    if paper.get("createdDate"):
        dates.append("created " + str(paper["createdDate"]))
    if paper.get("updateDate"):
        dates.append("updated " + str(paper["updateDate"]))
    if dates:
        lines.append("Dates: " + "; ".join(dates))
    lines.append("")
    lines.append("## Abstract")
    lines.append(" ".join((paper.get("abstract") or "(no abstract)").split()))
    return "\n".join(lines)


def extract_paper(data):
    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    paper = payload.get("paper")
    if isinstance(paper, dict):
        return paper
    if isinstance(payload, dict) and (payload.get("paperId") or payload.get("title")):
        return payload
    return None


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    if len(args) != 1 or args[0].startswith("--"):
        print("usage: web_research_inspect.py <paperId> [--json]", file=sys.stderr)
        return 2
    paper_id = args[0]

    path = "/v1/research/papers/" + urllib.parse.quote(paper_id, safe="")
    try:
        data = fc.call(path, method="GET")
    except fc.FcError as e:
        print(f"RESEARCH INSPECT FAILED for {paper_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(fmt_paper_metadata(extract_paper(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_INSPECT_PY

# --- local-search/local-web-search/scripts/web_research_related.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_research_related.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_RELATED_PY'
#!/usr/bin/env python3
"""Find research papers related to seed papers via the Firecrawl citation
graph (the firecrawl_research_related_papers MCP tool).

Usage:
    python web_research_related.py <seedId> [seedId ...] --intent "what to rank for"
                                   [--mode similar|citers|references] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

One to ten seed paper IDs (positional); the first is the primary seed, the
rest are anchors. `--intent` (required) is a short natural-language
description that ranks the candidates. `--mode` defaults to `similar`
(co-citation / bibliographic coupling); `citers` returns papers citing a
seed, `references` papers cited by a seed.

Prints the ranked candidates like web_research_search.py, then
`(poolSize=N)` and any `note:` from the API. `--json` prints the raw API
response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal
import web_research_search  # sibling: shared paper formatters

ENDPOINT = fc.url("/v1/research/related")

MODES = ("similar", "citers", "references")


def main() -> int:
    args = sys.argv[1:]
    seeds, intent, mode, as_json = [], None, None, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--intent" and i + 1 < len(args):
            i += 1
            intent = args[i]
        elif a == "--mode" and i + 1 < len(args):
            i += 1
            mode = args[i]
            if mode not in MODES:
                print(f"invalid --mode: {mode} (one of {', '.join(MODES)})",
                      file=sys.stderr)
                return 2
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            seeds.append(a)
        i += 1

    if not seeds or not intent:
        print('usage: web_research_related.py <seedId> [seedId ...] '
              '--intent "what to rank for" '
              '[--mode similar|citers|references] [--json]', file=sys.stderr)
        return 2
    if not 1 <= len(seeds) <= 10:
        print("provide one to ten seed paper IDs (first is the primary seed)",
              file=sys.stderr)
        return 2

    body = {"seed_ids": seeds, "intent": intent}
    if mode:
        body["mode"] = mode

    try:
        data = fc.call("/v1/research/related", method="POST", body=body)
    except fc.FcError as e:
        print(f"RESEARCH RELATED FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    print(web_research_search.fmt_hits(
        web_research_search.extract_results(data)))
    pool_size = payload.get("poolSize") or 0
    print(f"(poolSize={pool_size})")
    note = payload.get("note")
    if note:
        print(f"note: {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_RELATED_PY

# --- local-search/local-web-search/scripts/web_research_read.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_research_read.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_READ_PY'
#!/usr/bin/env python3
"""Read in-body passages from one research paper that are relevant to a
specific question (the firecrawl_research_read_paper MCP tool). Full text is
available only for indexed papers.

Usage:
    python web_research_read.py <paperId> "<question>" [--json]

Example:
    python web_research_read.py arxiv:1706.03762 "how is attention computed?"

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the matching passages separated by `---` lines (like the MCP tool), or
a notice when no full text is available. `--json` prints the raw API
response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/research/papers")


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    if len(args) != 2 or args[0].startswith("--") or args[1].startswith("--"):
        print('usage: web_research_read.py <paperId> "<question>" [--json]',
              file=sys.stderr)
        return 2
    paper_id, question = args

    path = ("/v1/research/papers/" + urllib.parse.quote(paper_id, safe="")
            + "/read")
    try:
        data = fc.call(path, method="POST", body={"question": question})
    except fc.FcError as e:
        print(f"RESEARCH READ FAILED for {paper_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    passages = data.get("passages")
    if passages is None:
        payload = data.get("data") if isinstance(data.get("data"), dict) \
            else data
        passages = payload.get("passages")
    if not isinstance(passages, list) or not passages:
        print("(no full-text passages available for this paper)")
        return 0
    texts = [p.get("text") if isinstance(p, dict) else str(p)
             for p in passages]
    print("\n---\n".join(t for t in texts if t))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_READ_PY

# --- local-search/local-web-search/scripts/web_github_search.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_github_search.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_GITHUB_SEARCH_PY'
#!/usr/bin/env python3
"""Search indexed public GitHub issue, pull-request, and README content via
the Firecrawl research index (the firecrawl_research_search_github MCP
tool).

Usage:
    python web_github_search.py "<query>" [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the ranked matches exactly like the MCP tool does — for each hit:

    [repo#123] (pull_request, 5 segments)
    https://github.com/...
    matched content (up to 1200 chars)

`--json` prints the raw API response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/research/search/github")

MAX_CONTENT_CHARS = 1200


def fmt_github(results):
    """Format ranked GitHub matches (mirrors the MCP tool's formatter)."""
    if not results:
        return "(no results)"
    blocks = []
    for r in results:
        if not isinstance(r, dict):
            blocks.append(str(r))
            continue
        lines = []
        repo = r.get("repo") or "?"
        number = r.get("number")
        if number is None and r.get("pageType") is None:
            lines.append(f"[{repo}] README")
        else:
            ref = f"#{number}" if number is not None else ""
            meta_parts = [str(r.get("pageType") or "")]
            if r.get("segmentCount"):
                meta_parts.append(f"{r['segmentCount']} segments")
            meta = ", ".join(p for p in meta_parts if p)
            lines.append(f"[{repo}{ref}]" + (f" ({meta})" if meta else ""))
        url = r.get("readmeUrl") or r.get("url")
        if url:
            lines.append(url)
        body = (r.get("contentMd") or r.get("snippet") or "").strip()
        lines.append(body[:MAX_CONTENT_CHARS] if body else "(no content)")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    query = " ".join(args).strip()
    if not query:
        print('usage: web_github_search.py "<query>" [--json]', file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/research/search/github", method="POST",
                       body={"query": query})
    except fc.FcError as e:
        print(f"GITHUB SEARCH FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    results = data.get("results")
    if results is None:
        payload = data.get("data") if isinstance(data.get("data"), dict) \
            else data
        results = payload.get("results")
    if not isinstance(results, list):
        results = []
    print(fmt_github(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_GITHUB_SEARCH_PY

# --- local-search/local-web-search/scripts/web_developer_search.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_developer_search.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_DEVELOPER_SEARCH_PY'
#!/usr/bin/env python3
"""Search the Firecrawl developer index — built for coding agents, covering
GitHub issues, merged pull requests, repository READMEs, and curated
documentation sites (the firecrawl_developer_search MCP tool).

Usage:
    python web_developer_search.py "<query>" [--skills-only] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Use it for developer questions — code behaviour, a library or framework, an
API contract, an error message, or a known bug. `--skills-only` limits the
search to agent-skill files. Prints the ranked results exactly like the MCP
tool does — for each hit:

    ## [id] (kind) title
    https://...
    matched passages (up to 1200 chars, separated by ---)

`--json` prints the raw API response instead.

NOTE: developer search needs a Firecrawl account with developer-search
permissions (set FIRECRAWL_API_KEY, and
FIRECRAWL_API_URL=https://api.firecrawl.dev for the cloud API); the
self-hosted stack may not expose it.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/developer/search")

MAX_PASSAGE_CHARS = 1200


def fmt_developer(results):
    """Format ranked developer-index results (mirrors the MCP formatter)."""
    if not results:
        return "(no results)"
    blocks = []
    for r in results:
        if not isinstance(r, dict):
            blocks.append(str(r))
            continue
        rid = r.get("id") or "?"
        kind = str(rid).split(":", 1)[0]
        lines = ["## [{}]{} {}".format(rid, f" ({kind})" if kind else "",
                                       r.get("title") or "(untitled)")]
        if r.get("url"):
            lines.append(r["url"])
        passages = r.get("passages")
        body = ""
        if isinstance(passages, list):
            body = "\n---\n".join((p.get("text") or "")
                                  if isinstance(p, dict) else str(p)
                                  for p in passages).strip()
        lines.append(body[:MAX_PASSAGE_CHARS] if body else "(no content)")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json" and a != "--skills-only"]
    as_json = "--json" in sys.argv[1:]
    skills_only = "--skills-only" in sys.argv[1:]
    query = " ".join(args).strip()
    if not query:
        print('usage: web_developer_search.py "<query>" [--skills-only] [--json]',
              file=sys.stderr)
        return 2

    body = {"query": query}
    if skills_only:
        body["skills"] = "only"

    try:
        data = fc.call("/v1/developer/search", method="POST", body=body)
    except fc.FcError as e:
        print(f"DEVELOPER SEARCH FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    results = data.get("results")
    if results is None:
        payload = data.get("data") if isinstance(data.get("data"), dict) \
            else data
        results = payload.get("results") or payload.get("developer")
    if not isinstance(results, list):
        results = []
    print(fmt_developer(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_DEVELOPER_SEARCH_PY

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
    # ---- bundled local-web-search agent skill (licensed by the top-level LICENSE) ----
    ("local-web-search/SKILL.md",                   "local-web-search/SKILL.md"),
    # core-only SKILL.md variant: materialised like any other file, then either
    # swapped in over SKILL.md (no Firecrawl account) or deleted (account mode)
    # by the trim step the generators emit near the skill installation.
    ("local-web-search/SKILL-core.md",              "local-web-search/SKILL-core.md"),
    ("local-web-search/scripts/config.py",          "local-web-search/scripts/config.py"),
    ("local-web-search/scripts/ensure_stack.py",    "local-web-search/scripts/ensure_stack.py"),
    ("local-web-search/scripts/firecrawl_api.py",   "local-web-search/scripts/firecrawl_api.py"),
    ("local-web-search/scripts/web_search.py",      "local-web-search/scripts/web_search.py"),
    ("local-web-search/scripts/web_scrape.py",      "local-web-search/scripts/web_scrape.py"),
    # ---- the 24 Firecrawl MCP-equivalent tools (web_search/web_scrape above + these 22) ----
    ("local-web-search/scripts/web_map.py",         "local-web-search/scripts/web_map.py"),
    ("local-web-search/scripts/web_crawl.py",       "local-web-search/scripts/web_crawl.py"),
    ("local-web-search/scripts/web_crawl_status.py", "local-web-search/scripts/web_crawl_status.py"),
    ("local-web-search/scripts/web_agent.py",       "local-web-search/scripts/web_agent.py"),
    ("local-web-search/scripts/web_agent_status.py", "local-web-search/scripts/web_agent_status.py"),
    ("local-web-search/scripts/web_interact.py",    "local-web-search/scripts/web_interact.py"),
    ("local-web-search/scripts/web_interact_stop.py", "local-web-search/scripts/web_interact_stop.py"),
    ("local-web-search/scripts/web_parse.py",       "local-web-search/scripts/web_parse.py"),
    ("local-web-search/scripts/web_monitor_create.py", "local-web-search/scripts/web_monitor_create.py"),
    ("local-web-search/scripts/web_monitor_list.py",   "local-web-search/scripts/web_monitor_list.py"),
    ("local-web-search/scripts/web_monitor_get.py",    "local-web-search/scripts/web_monitor_get.py"),
    ("local-web-search/scripts/web_monitor_update.py", "local-web-search/scripts/web_monitor_update.py"),
    ("local-web-search/scripts/web_monitor_delete.py", "local-web-search/scripts/web_monitor_delete.py"),
    ("local-web-search/scripts/web_monitor_run.py",    "local-web-search/scripts/web_monitor_run.py"),
    ("local-web-search/scripts/web_monitor_checks.py", "local-web-search/scripts/web_monitor_checks.py"),
    ("local-web-search/scripts/web_monitor_check.py",  "local-web-search/scripts/web_monitor_check.py"),
    ("local-web-search/scripts/web_research_search.py",   "local-web-search/scripts/web_research_search.py"),
    ("local-web-search/scripts/web_research_inspect.py",  "local-web-search/scripts/web_research_inspect.py"),
    ("local-web-search/scripts/web_research_related.py",  "local-web-search/scripts/web_research_related.py"),
    ("local-web-search/scripts/web_research_read.py",     "local-web-search/scripts/web_research_read.py"),
    ("local-web-search/scripts/web_github_search.py",     "local-web-search/scripts/web_github_search.py"),
    ("local-web-search/scripts/web_developer_search.py",  "local-web-search/scripts/web_developer_search.py"),
    ("install-local-search.bat",             "install-local-search.bat"),
]


# The 19 account-gated tool scripts: they only work against a Firecrawl
# account (the cloud API), so the installers ask a y/N "Add a Firecrawl
# account?" question (default N) and, when answered N, delete these scripts
# from the bundled skill and swap in the core-only SKILL.md (SKILL-core.md).
ACCOUNT_TOOLS = [
    "web_agent.py", "web_agent_status.py",
    "web_interact.py", "web_interact_stop.py",
    "web_parse.py",
    "web_monitor_create.py", "web_monitor_list.py", "web_monitor_get.py",
    "web_monitor_update.py", "web_monitor_delete.py", "web_monitor_run.py",
    "web_monitor_checks.py", "web_monitor_check.py",
    "web_research_search.py", "web_research_inspect.py",
    "web_research_related.py", "web_research_read.py",
    "web_github_search.py", "web_developer_search.py",
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
    ap('REM  Local Search Installer  (Firecrawl + SearXNG + local-web-search skill)  -  Windows')
    ap('REM ===========================================================================')
    ap('REM  Self-contained: every file the installer needs is embedded below as')
    ap('REM  base64. If a source file is missing from this script\'s folder (e.g. you')
    ap('REM  only downloaded this one .bat), the embedded copy is used instead.')
    ap('REM  After installing the stack it also copies the bundled local-web-search agent')
    ap('REM  skill into %USERPROFILE%\\.agents\\skills\\local-web-search.')
    ap('REM  The installer asks a y/N "Add a Firecrawl account?" question (default N):')
    ap('REM  without an account only the free local skill tools are installed (the')
    ap('REM  19 account-gated scripts are skipped and a core-only SKILL.md is used);')
    ap('REM  with one the credentials are written to .env and all 24 tools install.')
    ap('REM  If the Docker engine is not running, the installer launches Docker')
    ap('REM  Desktop automatically and waits for it before pulling images.')
    ap('REM ===========================================================================')
    ap('')
    ap('echo ============================================================')
    ap('echo   Local Search Installer  (Firecrawl + SearXNG + local-web-search)')
    ap('echo   A local web-browsing system for AI models.')
    ap('echo ============================================================')
    ap('echo.')
    ap('')
    # Docker check (auto-launch Docker Desktop when the engine is down)
    ap('where docker >nul 2>&1')
    ap('if errorlevel 1 (')
    ap('  echo [ERROR] Docker was not found on your PATH.')
    ap('  echo   Install Docker Desktop: https://www.docker.com/products/docker-desktop/')
    ap('  echo   Then re-run this installer.')
    ap('  pause & exit /b 1')
    ap(')')
    ap('docker info >nul 2>&1')
    ap('if not errorlevel 1 goto docker_ok')
    ap('echo [NOTE] The Docker engine is not running - trying to start Docker Desktop...')
    ap('set "DD_EXE="')
    ap('if exist "%ProgramFiles%\\Docker\\Docker\\Docker Desktop.exe" set "DD_EXE=%ProgramFiles%\\Docker\\Docker\\Docker Desktop.exe"')
    ap('if not defined DD_EXE if exist "%ProgramFiles(x86)%\\Docker\\Docker\\Docker Desktop.exe" set "DD_EXE=%ProgramFiles(x86)%\\Docker\\Docker\\Docker Desktop.exe"')
    ap('if not defined DD_EXE if exist "%LOCALAPPDATA%\\Programs\\Docker Desktop\\Docker Desktop.exe" set "DD_EXE=%LOCALAPPDATA%\\Programs\\Docker Desktop\\Docker Desktop.exe"')
    ap('if not defined DD_EXE (')
    ap('  echo [ERROR] Docker Desktop was not found in the usual install locations.')
    ap('  echo   Start it manually, wait until it says "running", then re-run')
    ap('  echo   this installer.')
    ap('  pause & exit /b 1')
    ap(')')
    ap('echo     Launching: "!DD_EXE!"')
    ap('start "" "!DD_EXE!"')
    ap('set "DD_LAUNCHED=1"')
    ap('echo     Docker Desktop is starting in the background. Answer the next')
    ap('echo     questions while it boots - the installer waits for the engine')
    ap('echo     before pulling images.')
    ap(':docker_ok')
    ap('if not defined DD_LAUNCHED echo [OK] Docker is running.')
    ap('echo.')
    ap('')
    # Source folder
    ap('set "SRC=%~dp0"')
    ap('if "!SRC:~-1!"=="\\" set "SRC=!SRC:~0,-1!"')
    ap('')
    # Prompts
    ap('set "DEFAULT_TARGET=%USERPROFILE%\\local-search"')
    ap('')
    ap('echo --- Step 1 of 5: Install location --------------------------')
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
    ap('echo --- Step 2 of 5: SearXNG port (default 9990) --------------')
    ap('set "SEARXNG_PORT="')
    ap('set /p SEARXNG_PORT="  Port for SearXNG [press Enter for 9990]: "')
    ap('if "!SEARXNG_PORT!"=="" set "SEARXNG_PORT=9990"')
    ap('call :validate_port "!SEARXNG_PORT!"')
    ap('if !errorlevel! neq 0 ( echo   [WARNING] "!SEARXNG_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_searxng )')
    ap('')
    ap(':ask_firecrawl')
    ap('echo --- Step 3 of 5: Firecrawl port (default 9991) ------------')
    ap('set "FIRECRAWL_PORT="')
    ap('set /p FIRECRAWL_PORT="  Port for Firecrawl [press Enter for 9991]: "')
    ap('if "!FIRECRAWL_PORT!"=="" set "FIRECRAWL_PORT=9991"')
    ap('call :validate_port "!FIRECRAWL_PORT!"')
    ap('if !errorlevel! neq 0 ( echo   [WARNING] "!FIRECRAWL_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_firecrawl )')
    ap('if /i "!FIRECRAWL_PORT!"=="!SEARXNG_PORT!" ( echo   [WARNING] Firecrawl port must differ from SearXNG port. & echo. & goto ask_firecrawl )')
    ap('')
    ap('echo.')
    ap('echo --- Step 4 of 5: Local LLM (optional) ---------------------')
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
    # Step 5: optional Firecrawl account (unlocks the account-gated tools)
    # NOTE: every echo line must carry balanced (or ^-escaped) parens -
    # an unescaped unbalanced "(" makes real cmd.exe swallow the NEXT line
    # as a continuation and die with a syntax error (the window just closes).
    ap('echo --- Step 5 of 5: Firecrawl account (optional) -------------')
    ap('echo   The extra tools ^(research agent, live-page interact, file parse,')
    ap('echo   monitors, paper research, GitHub/developer search^) only work')
    ap('echo   with a Firecrawl account API key ^(paid cloud service^):')
    ap('echo     https://www.firecrawl.dev')
    ap('echo   Answer N to install only the free local tools ^(default^).')
    ap('set "USE_FC="')
    ap('set /p USE_FC="  Add a Firecrawl account now? [y/N]: "')
    ap('set "FC_API_KEY="')
    ap('set "FC_API_URL="')
    ap('if /i not "!USE_FC!"=="y" goto fc_done')
    ap('set "FC_TRIES=0"')
    ap(':ask_fckey')
    ap('set "FC_API_KEY="')
    ap('set /p FC_API_KEY="    Firecrawl API key (from https://www.firecrawl.dev): "')
    ap('if not "!FC_API_KEY!"=="" goto fckey_ok')
    ap('set /a FC_TRIES+=1')
    ap('if !FC_TRIES! geq 3 (')
    ap('  echo     [WARNING] No API key entered - continuing WITHOUT a Firecrawl account.')
    ap('  goto fc_done')
    ap(')')
    ap('echo     [WARNING] The API key cannot be empty - try again.')
    ap('goto ask_fckey')
    ap(':fckey_ok')
    ap('set "FC_API_URL="')
    ap('set /p FC_API_URL="    Firecrawl API URL [press Enter for https://api.firecrawl.dev]: "')
    ap('if "!FC_API_URL!"=="" set "FC_API_URL=https://api.firecrawl.dev"')
    ap(':fc_done')
    ap('echo.')
    # Summary + confirm
    ap('echo.')
    ap('echo ============================================================')
    ap('echo   Summary')
    ap('echo   Folder:         !TARGET!')
    ap('echo   SearXNG port:   !SEARXNG_PORT!')
    ap('echo   Firecrawl port: !FIRECRAWL_PORT!')
    ap('echo   Agent skill:    %USERPROFILE%\\.agents\\skills\\local-web-search')
    ap('if defined OPENAI_BASE_URL (')
    ap('  echo   LLM endpoint:   !OPENAI_BASE_URL!  !MODEL_NAME!')
    ap(') else (')
    ap('  echo   LLM endpoint:   ^(none - enable later by editing .env^)')
    ap(')')
    ap('if defined FC_API_KEY (')
    ap('  echo   Firecrawl acct: !FC_API_URL!  ^(account tools installed^)')
    ap(') else (')
    ap('  echo   Firecrawl acct: ^(none - free local tools only^)')
    ap(')')
    ap('echo ============================================================')
    ap('set "CONFIRM="')
    ap('set /p CONFIRM="Proceed with install? [Y/n]: "')
    ap('if /i "!CONFIRM!"=="n" ( echo Install cancelled. & pause & exit /b 0 )')
    ap('')
    # Create folders
    ap('if not exist "!TARGET!" mkdir "!TARGET!"')
    ap('if not exist "!TARGET!\\config\\searxng" mkdir "!TARGET!\\config\\searxng"')
    ap('if not exist "!TARGET!\\local-web-search\\scripts" mkdir "!TARGET!\\local-web-search\\scripts"')
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
    ap('if defined FC_API_KEY (')
    ap('  >> "!TARGET!\\.env" echo.')
    # NOTE: this echo line lives INSIDE the `if defined FC_API_KEY ( ... )`
    # block. In cmd block parsing, an unquoted/unescaped ")" in echo text
    # CLOSES THE BLOCK EARLY ( "(" in text is inert, ")" is structural ),
    # so "(cloud API)" would end the block at "API)" and the rest of the
    # line becomes a top-level command -> "FOR was unexpected at this time"
    # -> real cmd.exe aborts the whole installer. Escape both parens.
    ap('  >> "!TARGET!\\.env" echo # ---- Firecrawl account ^(cloud API^) for account-only tools ----')
    ap('  >> "!TARGET!\\.env" echo FIRECRAWL_API_URL=!FC_API_URL!')
    ap('  >> "!TARGET!\\.env" echo FIRECRAWL_API_KEY=!FC_API_KEY!')
    ap(')')
    ap('')
    # Inject SearXNG secret into settings.yml
    ap('echo Injecting SearXNG secret into settings.yml ...')
    ap('powershell -NoProfile -Command "(Get-Content -Raw \'!TARGET!\\config\\searxng\\settings.yml\') -replace \'__SEARXNG_SECRET_PLACEHOLDER__\', \'!SECRET!\' | Set-Content -NoNewline \'!TARGET!\\config\\searxng\\settings.yml\'"')
    ap('')
    # -------------------------------------------------------------------
    #  Core-only trim: without a Firecrawl account, remove the 19
    #  account-gated scripts from the bundled skill and swap in the
    #  core-only SKILL.md so the installed skill matches what works.
    # -------------------------------------------------------------------
    ap('if defined FC_API_KEY goto skill_full')
    ap('echo Installing the core-only local-web-search skill (no Firecrawl account)...')
    for name in ACCOUNT_TOOLS:
        rel_win = "local-web-search\\scripts\\" + name
        ap('if exist "!TARGET!\\' + rel_win + '" del /Q "!TARGET!\\' + rel_win + '" >nul 2>&1')
    ap('if exist "!TARGET!\\local-web-search\\SKILL-core.md" copy /Y "!TARGET!\\local-web-search\\SKILL-core.md" "!TARGET!\\local-web-search\\SKILL.md" >nul')
    ap(':skill_full')
    ap('REM SKILL-core.md is a build-time variant - never part of an installed skill.')
    ap('if exist "!TARGET!\\local-web-search\\SKILL-core.md" del /Q "!TARGET!\\local-web-search\\SKILL-core.md" >nul 2>&1')
    ap('')
    # -------------------------------------------------------------------
    #  Install the bundled local-web-search agent skill into the user's skills
    #  directory (add/override), and record the install path hint.
    # -------------------------------------------------------------------
    ap('echo Installing the local-web-search agent skill...')
    ap('set "SKILL_DIR=%USERPROFILE%\\.agents\\skills\\local-web-search"')
    ap('if exist "!SKILL_DIR!" rd /s /q "!SKILL_DIR!"')
    ap('if not exist "%USERPROFILE%\\.agents\\skills" mkdir "%USERPROFILE%\\.agents\\skills"')
    ap('xcopy /E /I /Y /Q "!TARGET!\\local-web-search" "!SKILL_DIR!" >nul')
    ap('if errorlevel 1 (')
    ap('  echo   [WARNING] Could not copy the local-web-search skill to !SKILL_DIR!.')
    ap(') else (')
    ap('  > "!TARGET!\\local-web-search\\install-dir.txt" echo !TARGET!')
    ap('  > "!SKILL_DIR!\\install-dir.txt" echo !TARGET!')
    ap('  echo   Agent skill installed: !SKILL_DIR!')
    ap(')')
    ap('')
    # Wait for the engine if we launched Docker Desktop earlier (the prompts
    # above ran while it was booting in the background).
    ap('REM How long to wait for a just-launched Docker engine to come online (seconds).')
    ap('set "DD_TIMEOUT=300"')
    ap('if defined LOCAL_SEARCH_DOCKER_TIMEOUT set "DD_TIMEOUT=!LOCAL_SEARCH_DOCKER_TIMEOUT!"')
    ap('if not defined DD_LAUNCHED goto docker_engine_ready')
    ap('echo Waiting for the Docker engine to come online - up to !DD_TIMEOUT! seconds...')
    ap('set /a DD_WAIT=0')
    ap(':docker_wait')
    ap('timeout /t 5 /nobreak >nul 2>&1')
    ap('if errorlevel 1 ping -n 6 127.0.0.1 >nul 2>&1')
    ap('set /a DD_WAIT+=5')
    ap('docker info >nul 2>&1')
    ap('if not errorlevel 1 goto docker_engine_ready')
    ap('if !DD_WAIT! geq !DD_TIMEOUT! (')
    ap('  echo [ERROR] The Docker engine did not come online within !DD_TIMEOUT! seconds.')
    ap('  echo   Check Docker Desktop for errors, wait until it says "running",')
    ap('  echo   then re-run this installer.')
    ap('  pause & exit /b 1')
    ap(')')
    ap('set /a "DD_MOD=DD_WAIT %% 15"')
    ap('if !DD_MOD! equ 0 echo     ... still waiting !DD_WAIT!s')
    ap('goto docker_wait')
    ap(':docker_engine_ready')
    ap('if defined DD_LAUNCHED echo [OK] Docker engine is online after !DD_WAIT!s.')
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
    ap('echo   local-web-search skill:              %USERPROFILE%\\.agents\\skills\\local-web-search')
    ap('echo.')
    ap('echo   If your agent was already running, restart it so it picks up')
    ap('echo   the new skill.')
    ap('echo.')
    ap('echo   Manage the stack with the .bat files in:')
    ap('echo     !TARGET!')
    ap('echo       Run.bat   Stop.bat   Update.bat   Uninstall.bat')
    ap('echo.')
    ap('echo   See README.md for how to connect this to your AI models')
    ap('echo   (local-web-search skill, LM Studio, MCP server, direct prompting, etc.).')
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
    ap('#  Local Search Installer  (Firecrawl + SearXNG + local-web-search skill)')
    ap('#                        -  Linux & macOS')
    ap('# =============================================================================')
    ap('#  Self-contained: every file the installer needs is embedded below as a')
    ap('#  quoted heredoc. If a source file is missing from this script\'s folder')
    ap('#  (e.g. you only downloaded this one .sh), the embedded copy is used.')
    ap('#  After installing the stack it also copies the bundled local-web-search agent')
    ap('#  skill into ~/.agents/skills/local-web-search.')
    ap('#  The installer asks a y/N "Add a Firecrawl account?" question (default N):')
    ap('#  without an account only the free local skill tools are installed (the')
    ap('#  19 account-gated scripts are skipped and a core-only SKILL.md is used);')
    ap('#  with one the credentials are written to .env and all 24 tools install.')
    ap('#  If the Docker engine is not running, the installer tries to start it')
    ap('#  automatically (Docker Desktop on macOS, systemctl/service on Linux)')
    ap('#  and waits for it before pulling images.')
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
    ap('  Local Search Installer  (Firecrawl + SearXNG + local-web-search)')
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
    # Docker engine check - try to START it automatically when it is down.
    ap('# How long to wait for a just-launched Docker engine (seconds).')
    ap('DOCKER_WAIT_TIMEOUT="${LOCAL_SEARCH_DOCKER_TIMEOUT:-300}"')
    ap('ENGINE_LAUNCHED=0')
    ap('if ! docker info >/dev/null 2>&1; then')
    ap('  say "  ${YELLOW}[!]${RESET} The Docker engine is not running - trying to start it..."')
    ap('  ENGINE_STARTED=0')
    ap('  if [ "$(uname)" = "Darwin" ]; then')
    ap('    # macOS: launch Docker Desktop if it is installed')
    ap('    if command -v open >/dev/null 2>&1 \\')
    ap('       && { [ -d "/Applications/Docker.app" ] || [ -d "$HOME/Applications/Docker.app" ]; }; then')
    ap('      open -a Docker >/dev/null 2>&1 && ENGINE_STARTED=1')
    ap('    fi')
    ap('  else')
    ap('    # Linux: systemd units (Docker Desktop uses docker-desktop, the')
    ap('    # classic engine uses docker), then service(1). Non-interactive')
    ap('    # sudo only - an installer never prompts for a password.')
    ap('    if command -v systemctl >/dev/null 2>&1; then')
    ap('      for unit in docker-desktop docker; do')
    ap('        if systemctl start "$unit" >/dev/null 2>&1; then ENGINE_STARTED=1; break; fi')
    ap('        if command -v sudo >/dev/null 2>&1 \\')
    ap('           && sudo -n systemctl start "$unit" >/dev/null 2>&1; then')
    ap('          ENGINE_STARTED=1; break')
    ap('        fi')
    ap('      done')
    ap('    fi')
    ap('    if [ "$ENGINE_STARTED" -ne 1 ] && command -v service >/dev/null 2>&1; then')
    ap('      if service docker start >/dev/null 2>&1; then ENGINE_STARTED=1')
    ap('      elif command -v sudo >/dev/null 2>&1 \\')
    ap('         && sudo -n service docker start >/dev/null 2>&1; then')
    ap('        ENGINE_STARTED=1')
    ap('      fi')
    ap('    fi')
    ap('  fi')
    ap('  if [ "$ENGINE_STARTED" -ne 1 ]; then')
    ap('    err "Could not start the Docker engine automatically."')
    ap('    say ""')
    ap('    say "Start it manually, then re-run this installer:"')
    ap('    say "  Linux:  sudo systemctl start docker    (or launch Docker Desktop)"')
    ap('    say "          permission denied from docker? add yourself to the docker"')
    ap('    say "          group:  sudo usermod -aG docker $USER  (log out and back in)"')
    ap('    say "  macOS:  open -a Docker"')
    ap('    exit 1')
    ap('  fi')
    ap('  ENGINE_LAUNCHED=1')
    ap('  say "  Launched Docker in the background. Answer the next questions while"')
    ap('  say "  it boots - the installer waits for the engine before pulling images."')
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
    ap('hdr "Step 1 of 5: Install location"')
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
    ap('hdr "Step 2 of 5: SearXNG port (default 9990)"')
    ap('while true; do')
    ap('  printf "  Port for SearXNG [press Enter for 9990]: "')
    ap('  read -r SEARXNG_PORT')
    ap('  [ -z "$SEARXNG_PORT" ] && SEARXNG_PORT=9990')
    ap('  if validate_port "$SEARXNG_PORT"; then break; fi')
    ap('  say "  ${YELLOW}[!]${RESET} \'$SEARXNG_PORT\' is not a valid port (1-65535)."')
    ap('done')
    ap('')
    ap('hdr "Step 3 of 5: Firecrawl port (default 9991)"')
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
    ap('hdr "Step 4 of 5: Local LLM (optional)"')
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
    # Step 5: optional Firecrawl account (unlocks the account-gated tools)
    ap('hdr "Step 5 of 5: Firecrawl account (optional)"')
    ap('say "  The extra tools (research agent, live-page interact, file parse,"')
    ap('say "  monitors, paper research, GitHub/developer search) only work"')
    ap('say "  with a Firecrawl account API key (paid cloud service):"')
    ap('say "    https://www.firecrawl.dev"')
    ap('say "  Answer N to install only the free local tools (default)."')
    ap('printf "  Add a Firecrawl account now? [y/N]: "')
    ap('USE_FC=""')
    ap('read -r USE_FC || USE_FC=""')
    ap('FC_API_KEY=""; FC_API_URL=""')
    ap('if [ "$(lower "$USE_FC")" = "y" ]; then')
    ap('  FC_TRIES=0')
    ap('  while true; do')
    ap('    printf "    Firecrawl API key (from https://www.firecrawl.dev): "')
    ap('    if ! read -r FC_API_KEY; then FC_API_KEY=""; break; fi')
    ap('    [ -n "$FC_API_KEY" ] && break')
    ap('    FC_TRIES=$((FC_TRIES + 1))')
    ap('    if [ "$FC_TRIES" -ge 3 ]; then')
    ap('      say "    ${YELLOW}[!]${RESET} no API key entered - continuing WITHOUT a Firecrawl account."')
    ap('      FC_API_KEY=""')
    ap('      break')
    ap('    fi')
    ap('    say "    ${YELLOW}[!]${RESET} the API key cannot be empty - try again."')
    ap('  done')
    ap('  if [ -n "$FC_API_KEY" ]; then')
    ap('    printf "    Firecrawl API URL [press Enter for https://api.firecrawl.dev]: "')
    ap('    read -r FC_API_URL || FC_API_URL=""')
    ap('    [ -z "$FC_API_URL" ] && FC_API_URL="https://api.firecrawl.dev"')
    ap('  fi')
    ap('fi')
    ap('')
    # Summary + confirm
    ap('echo')
    ap('say "${BOLD}============================================================${RESET}"')
    ap('say "${BOLD}  Summary${RESET}"')
    ap('say "  Folder:         $TARGET"')
    ap('say "  SearXNG port:   $SEARXNG_PORT"')
    ap('say "  Firecrawl port: $FIRECRAWL_PORT"')
    ap('say "  Agent skill:    $HOME/.agents/skills/local-web-search"')
    ap('if [ -n "$OPENAI_BASE_URL" ]; then')
    ap('  say "  LLM endpoint:   $OPENAI_BASE_URL  $MODEL_NAME"')
    ap('else')
    ap('  say "  LLM endpoint:   (none - enable later by editing .env)"')
    ap('fi')
    ap('if [ -n "$FC_API_KEY" ]; then')
    ap('  say "  Firecrawl acct: $FC_API_URL  (account tools installed)"')
    ap('else')
    ap('  say "  Firecrawl acct: (none - free local tools only)"')
    ap('fi')
    ap('say "${BOLD}============================================================${RESET}"')
    ap('printf "Proceed with install? [Y/n]: "')
    ap('read -r CONFIRM')
    ap('if [ "$(lower "$CONFIRM")" = "n" ]; then say "Install cancelled."; exit 0; fi')
    ap('')
    # Create folders
    ap('mkdir -p "$TARGET/config/searxng" "$TARGET/local-web-search/scripts"')
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
    ap('  if [ -n "$FC_API_KEY" ]; then')
    ap('    echo')
    ap('    echo "# ---- Firecrawl account (cloud API) for account-only tools ----"')
    ap('    echo "FIRECRAWL_API_URL=$FC_API_URL"')
    ap('    echo "FIRECRAWL_API_KEY=$FC_API_KEY"')
    ap('  fi')
    ap('} > "$TARGET/.env"')
    ap('')
    # Inject secret
    ap('say "Injecting SearXNG secret into settings.yml ..."')
    ap('SFILE="$TARGET/config/searxng/settings.yml"')
    ap('sed "s/__SEARXNG_SECRET_PLACEHOLDER__/$SECRET/" "$SFILE" > "$SFILE.tmp" && mv "$SFILE.tmp" "$SFILE"')
    ap('')
    # -------------------------------------------------------------------
    #  Core-only trim: without a Firecrawl account, remove the 19
    #  account-gated scripts from the bundled skill and swap in the
    #  core-only SKILL.md so the installed skill matches what works.
    # -------------------------------------------------------------------
    ap('if [ -z "$FC_API_KEY" ]; then')
    ap('  say "Installing the core-only local-web-search skill (no Firecrawl account)..."')
    for name in ACCOUNT_TOOLS:
        ap('  rm -f "$TARGET/local-web-search/scripts/' + name + '"')
    ap('  if [ -f "$TARGET/local-web-search/SKILL-core.md" ]; then cp -f "$TARGET/local-web-search/SKILL-core.md" "$TARGET/local-web-search/SKILL.md"; fi')
    ap('fi')
    ap('# SKILL-core.md is a build-time variant - never part of an installed skill.')
    ap('rm -f "$TARGET/local-web-search/SKILL-core.md"')
    ap('')
    # -------------------------------------------------------------------
    #  Install the bundled local-web-search agent skill into the user's skills
    #  directory (add/override), and record the install path hint.
    # -------------------------------------------------------------------
    ap('say "Installing the local-web-search agent skill..."')
    ap('SKILL_DIR="$HOME/.agents/skills/local-web-search"')
    ap('rm -rf "$SKILL_DIR"')
    ap('mkdir -p "$HOME/.agents/skills"')
    ap('if cp -r "$TARGET/local-web-search" "$SKILL_DIR"; then')
    ap('  printf \'%s\\n\' "$TARGET" > "$TARGET/local-web-search/install-dir.txt"')
    ap('  printf \'%s\\n\' "$TARGET" > "$SKILL_DIR/install-dir.txt"')
    ap('  say "  Agent skill installed: $SKILL_DIR"')
    ap('else')
    ap('  say "  ${YELLOW}[WARNING]${RESET} could not copy the local-web-search skill to $SKILL_DIR"')
    ap('fi')
    ap('')
    # If we launched the engine above, wait for it to come online now (the
    # prompts above ran while it was booting in the background).
    ap('if [ "$ENGINE_LAUNCHED" = "1" ]; then')
    ap('  say "Waiting for the Docker engine to come online - up to ${DOCKER_WAIT_TIMEOUT}s..."')
    ap('  DD_WAIT=0')
    ap('  while ! docker info >/dev/null 2>&1; do')
    ap('    sleep 5')
    ap('    DD_WAIT=$((DD_WAIT + 5))')
    ap('    if [ "$DD_WAIT" -ge "$DOCKER_WAIT_TIMEOUT" ]; then')
    ap('      err "The Docker engine did not come online within ${DOCKER_WAIT_TIMEOUT}s."')
    ap('      say "  Check Docker Desktop or: sudo systemctl status docker"')
    ap('      say "  Linux permission denied from docker info? add yourself to the"')
    ap('      say "  docker group:  sudo usermod -aG docker $USER  (log out and back in)"')
    ap('      say "  then start Docker and re-run this installer."')
    ap('      exit 1')
    ap('    fi')
    ap('    if [ $((DD_WAIT % 15)) -eq 0 ]; then say "  ... still waiting, ${DD_WAIT}s elapsed"; fi')
    ap('  done')
    ap('  ok "Docker engine is online after ${DD_WAIT}s."')
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
    ap('say "  local-web-search skill:              $HOME/.agents/skills/local-web-search"')
    ap('echo')
    ap('say "  If your agent was already running, restart it so it picks up"')
    ap('say "  the new skill."')
    ap('echo')
    ap('say "  Manage the stack with the scripts in:"')
    ap('say "    $TARGET"')
    ap('say "      ./run.sh   ./stop.sh   ./update.sh   ./uninstall.sh"')
    ap('echo')
    ap('say "  See README.md for how to connect this to your AI models"')
    ap('say "  (local-web-search skill, LM Studio, MCP server, direct prompting, etc.)."')
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
  * the full local-search source tree (44 files; the generated installers
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
    "local-web-search/SKILL.md",
    # core-only SKILL.md variant: the installers swap it in over SKILL.md
    # when no Firecrawl account is configured (their "Add a Firecrawl
    # account?" question defaults to N)
    "local-web-search/SKILL-core.md",
    "local-web-search/scripts/config.py",
    "local-web-search/scripts/ensure_stack.py",
    "local-web-search/scripts/firecrawl_api.py",
    "local-web-search/scripts/web_search.py",
    "local-web-search/scripts/web_scrape.py",
    # ---- the 24 Firecrawl MCP-equivalent tools (web_search/web_scrape above + these 22) ----
    "local-web-search/scripts/web_map.py",
    "local-web-search/scripts/web_crawl.py",
    "local-web-search/scripts/web_crawl_status.py",
    "local-web-search/scripts/web_agent.py",
    "local-web-search/scripts/web_agent_status.py",
    "local-web-search/scripts/web_interact.py",
    "local-web-search/scripts/web_interact_stop.py",
    "local-web-search/scripts/web_parse.py",
    "local-web-search/scripts/web_monitor_create.py",
    "local-web-search/scripts/web_monitor_list.py",
    "local-web-search/scripts/web_monitor_get.py",
    "local-web-search/scripts/web_monitor_update.py",
    "local-web-search/scripts/web_monitor_delete.py",
    "local-web-search/scripts/web_monitor_run.py",
    "local-web-search/scripts/web_monitor_checks.py",
    "local-web-search/scripts/web_monitor_check.py",
    "local-web-search/scripts/web_research_search.py",
    "local-web-search/scripts/web_research_inspect.py",
    "local-web-search/scripts/web_research_related.py",
    "local-web-search/scripts/web_research_read.py",
    "local-web-search/scripts/web_github_search.py",
    "local-web-search/scripts/web_developer_search.py",
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
    ap('if not exist "!TARGET!\\local-search\\local-web-search\\scripts" mkdir "!TARGET!\\local-search\\local-web-search\\scripts"')
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
    ap('mkdir -p "$TARGET/local-search/config/searxng" "$TARGET/local-search/local-web-search/scripts"')
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
    install-local-search.sh    -> extracts the 20 local-search/ source files
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
    "local-web-search/SKILL.md",
    "local-web-search/SKILL-core.md",
    "local-web-search/scripts/config.py",
    "local-web-search/scripts/ensure_stack.py",
    "local-web-search/scripts/firecrawl_api.py",
    "local-web-search/scripts/web_search.py",
    "local-web-search/scripts/web_scrape.py",
    "local-web-search/scripts/web_map.py",
    "local-web-search/scripts/web_crawl.py",
    "local-web-search/scripts/web_crawl_status.py",
    "local-web-search/scripts/web_agent.py",
    "local-web-search/scripts/web_agent_status.py",
    "local-web-search/scripts/web_interact.py",
    "local-web-search/scripts/web_interact_stop.py",
    "local-web-search/scripts/web_parse.py",
    "local-web-search/scripts/web_monitor_create.py",
    "local-web-search/scripts/web_monitor_list.py",
    "local-web-search/scripts/web_monitor_get.py",
    "local-web-search/scripts/web_monitor_update.py",
    "local-web-search/scripts/web_monitor_delete.py",
    "local-web-search/scripts/web_monitor_run.py",
    "local-web-search/scripts/web_monitor_checks.py",
    "local-web-search/scripts/web_monitor_check.py",
    "local-web-search/scripts/web_research_search.py",
    "local-web-search/scripts/web_research_inspect.py",
    "local-web-search/scripts/web_research_related.py",
    "local-web-search/scripts/web_research_read.py",
    "local-web-search/scripts/web_github_search.py",
    "local-web-search/scripts/web_developer_search.py",
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

# ---- cmd.exe block-paren safety check on the .bat logic lines ----
# Real cmd.exe rule (verified against a real cmd.exe implementation):
#   * an unquoted/unescaped "(" in echo text is INERT (literal text),
#   * but an unquoted/unescaped ")" INSIDE a parenthesized block is
#     STRUCTURAL: it closes the block at that point. If the ")" is in the
#     middle of a command's text, the remainder of the statement becomes
#     top-level garbage -> "FOR was unexpected at this time" (or similar)
#     -> cmd.exe aborts the batch and the window closes.
# So: while a block is open, every unquoted/unescaped ")" must be a
# legitimate closer: a ")"-line, ") else (", or followed by do/&/|/EOL.
def _unquoted_parens(line):
    out = []
    j = 0; inq = False
    while j < len(line):
        c = line[j]
        if c == "^":
            j += 2; continue
        if c == '"':
            inq = not inq; j += 1; continue
        if not inq and c in "()":
            out.append((j, c))
        j += 1
    return out

_close_cont = re.compile(r'^(else\b|do\b|&|\||rem\b|::)', re.I)
b64line = re.compile(r'\s*>>?\s*"?!?B64TMP!?"?\s+echo\s+')
remline = re.compile(r'^\s*(REM\b|::)', re.I)
bat_lines = bat_text.split("\n")
paren_bad = []
depth = 0
for i, line in enumerate(bat_lines):
    if b64line.match(line) or remline.match(line) or not line.strip():
        continue
    # skip embedded-base64 temp-file writes
    ps = _unquoted_parens(line)
    closes = [p for p in ps if p[1] == ")"]
    opens = len([p for p in ps if p[1] == "("])
    # structural opens: "(" at end of line (if/for/do blocks) + inline
    # for-set/do opens ("in (", "do (")
    structural_opens = 0
    if line.rstrip().endswith("("):
        structural_opens += 1
    inline = len(re.findall(r"\bin\s*\(", line)) + len(re.findall(r"\bdo\s*\(", line))
    if line.rstrip().endswith("(") and inline:
        inline = max(0, inline - 1)
    structural_opens += inline
    if depth > 0 and closes:
        for pos, _ch in closes:
            after = line[pos + 1:].lstrip()
            if after == "" or _close_cont.match(after):
                continue  # legitimate closer
            paren_bad.append((i + 1, line.strip()))
            break
    depth += structural_opens - len(closes)
    if depth < 0:
        depth = 0  # top-level ")" in echo text is a literal, harmless
if paren_bad:
    print()
    print("[FAIL] unescaped ')' inside blocks (kills real cmd.exe):")
    for ln, txt in paren_bad:
        print("  L%d: %s" % (ln, txt))
    ok = False
else:
    print("paren check: no unescaped ')' inside blocks (cmd-safe)")

print()
print("ALL GOOD" if ok else "FAILURES PRESENT")
import sys
sys.exit(0 if ok else 1)
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
    "local-web-search/SKILL.md",
    "local-web-search/SKILL-core.md",
    "local-web-search/scripts/config.py",
    "local-web-search/scripts/ensure_stack.py",
    "local-web-search/scripts/firecrawl_api.py",
    "local-web-search/scripts/web_search.py",
    "local-web-search/scripts/web_scrape.py",
    "local-web-search/scripts/web_map.py",
    "local-web-search/scripts/web_crawl.py",
    "local-web-search/scripts/web_crawl_status.py",
    "local-web-search/scripts/web_agent.py",
    "local-web-search/scripts/web_agent_status.py",
    "local-web-search/scripts/web_interact.py",
    "local-web-search/scripts/web_interact_stop.py",
    "local-web-search/scripts/web_parse.py",
    "local-web-search/scripts/web_monitor_create.py",
    "local-web-search/scripts/web_monitor_list.py",
    "local-web-search/scripts/web_monitor_get.py",
    "local-web-search/scripts/web_monitor_update.py",
    "local-web-search/scripts/web_monitor_delete.py",
    "local-web-search/scripts/web_monitor_run.py",
    "local-web-search/scripts/web_monitor_checks.py",
    "local-web-search/scripts/web_monitor_check.py",
    "local-web-search/scripts/web_research_search.py",
    "local-web-search/scripts/web_research_inspect.py",
    "local-web-search/scripts/web_research_related.py",
    "local-web-search/scripts/web_research_read.py",
    "local-web-search/scripts/web_github_search.py",
    "local-web-search/scripts/web_developer_search.py",
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
#   * verifies the produced install folder, the ~/.agents/skills/local-web-search
#     skill install, the install-dir.txt hint, and the uninstaller.
#   * CORE-MODE test: the default (no Firecrawl account) install must skip
#     the 19 account-gated tool scripts and install the core-only SKILL.md.
#   * ACCOUNT-MODE test: re-runs the installer with a fake Firecrawl account
#     and verifies all 24 tools install, the credentials land in .env, and
#     firecrawl_api.py picks them up (routing the tools to the cloud API).
#   * SELF-HEAL test: fake SearXNG/Firecrawl HTTP servers + a mock
#     `docker compose up` that starts them, verifying that web_search.py /
#     web_scrape.py auto-start a down stack and retry (and report cleanly
#     when the stack cannot come up).
#   * DOCKER AUTO-START test: a mock docker whose engine is DOWN + a mock
#     systemctl that starts it, verifying the installer launches the engine
#     itself, waits for it, and completes (plus both failure paths).
# Any pre-existing ~/.agents/skills/local-web-search is backed up and restored.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$ROOT/local-search/install-local-search.sh"
TESTROOT="$ROOT/.ls-test-$$"
SRC_DIR="$TESTROOT/src-only-installer"
TGT_DIR="$TESTROOT/target"
MOCKBIN="$TESTROOT/bin"
SKILL_DIR="$HOME/.agents/skills/local-web-search"
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

# --- run the installer with scripted answers (CORE MODE: no account) --------
#   Step 1: target folder, Step 2: searxng port, Step 3: firecrawl port,
#   Step 4: connect LLM? -> n,  Step 5: Firecrawl account? -> n,  confirm -> y
printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$TGT_DIR" \
  "" \
  "" \
  "n" \
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
echo "Target local-web-search contents:"
find "$TGT_DIR/local-web-search" -type f | sort

check() {
  if [ -s "$TGT_DIR/$1" ]; then
    echo "  [OK]   $1  ($(wc -c < "$TGT_DIR/$1") bytes)"
  else
    echo "  [FAIL] $1  (missing or empty)"
    PASS=0
  fi
}
check_absent() {
  if [ -e "$TGT_DIR/$1" ]; then
    echo "  [FAIL] $1  (must NOT be installed without a Firecrawl account)"
    PASS=0
  else
    echo "  [OK]   $1  (absent - core-only install, as expected)"
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
check "local-web-search/SKILL.md"
check "local-web-search/scripts/config.py"
check "local-web-search/scripts/ensure_stack.py"
check "local-web-search/scripts/firecrawl_api.py"
check "local-web-search/scripts/web_search.py"
check "local-web-search/scripts/web_scrape.py"
check "local-web-search/scripts/web_map.py"
check "local-web-search/scripts/web_crawl.py"
check "local-web-search/scripts/web_crawl_status.py"
check "install-local-search.bat"
check "install-local-search.sh"

# --- core-only mode: the 19 account-gated scripts must NOT be installed ------
echo
echo "Checking the account-gated tools are NOT installed (no Firecrawl account):"
for f in web_agent.py web_agent_status.py web_interact.py web_interact_stop.py \
         web_parse.py web_monitor_create.py web_monitor_list.py \
         web_monitor_get.py web_monitor_update.py web_monitor_delete.py \
         web_monitor_run.py web_monitor_checks.py web_monitor_check.py \
         web_research_search.py web_research_inspect.py web_research_related.py \
         web_research_read.py web_github_search.py web_developer_search.py; do
  check_absent "local-web-search/scripts/$f"
done
check_absent "local-web-search/SKILL-core.md"

# SKILL.md must be the core-only variant (no account tools mentioned)
if grep -q "5 tools: search, scrape, map, crawl, crawl status" "$TGT_DIR/local-web-search/SKILL.md" \
   && ! grep -q "web_monitor_create" "$TGT_DIR/local-web-search/SKILL.md" \
   && ! grep -q "web_developer_search" "$TGT_DIR/local-web-search/SKILL.md"; then
  echo "  [OK]   local-web-search/SKILL.md is the core-only variant"
else
  echo "  [FAIL] local-web-search/SKILL.md is not the core-only variant"
  PASS=0
fi

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

# core mode: no Firecrawl account credentials in .env
if grep -q "^FIRECRAWL_API_KEY=" "$TGT_DIR/.env" \
   || grep -q "^FIRECRAWL_API_URL=" "$TGT_DIR/.env"; then
  echo "[FAIL] .env should not contain Firecrawl account credentials (core mode)"
  PASS=0
else
  echo "[OK] .env has no Firecrawl account credentials (core mode)"
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

# --- verify the skill was installed into ~/.agents/skills/local-web-search --------
echo
echo "Skill dir contents ($SKILL_DIR):"
find "$SKILL_DIR" -type f 2>/dev/null | sort

SKILL_FILES="SKILL.md scripts/config.py scripts/ensure_stack.py scripts/firecrawl_api.py \
         scripts/web_search.py scripts/web_scrape.py scripts/web_map.py \
         scripts/web_crawl.py scripts/web_crawl_status.py"

for f in $SKILL_FILES; do
  if [ -s "$SKILL_DIR/$f" ]; then
    echo "  [OK]   skill: $f"
  else
    echo "  [FAIL] skill: $f (missing or empty)"
    PASS=0
  fi
done

# core mode: the account-gated scripts must be absent from the skill dir too
SKILL_ABSENT="scripts/web_agent.py scripts/web_agent_status.py scripts/web_interact.py \
         scripts/web_interact_stop.py scripts/web_parse.py \
         scripts/web_monitor_create.py scripts/web_monitor_list.py \
         scripts/web_monitor_get.py scripts/web_monitor_update.py \
         scripts/web_monitor_delete.py scripts/web_monitor_run.py \
         scripts/web_monitor_checks.py scripts/web_monitor_check.py \
         scripts/web_research_search.py scripts/web_research_inspect.py \
         scripts/web_research_related.py scripts/web_research_read.py \
         scripts/web_github_search.py scripts/web_developer_search.py"
for f in $SKILL_ABSENT; do
  if [ -e "$SKILL_DIR/$f" ]; then
    echo "  [FAIL] skill: $f (must NOT be installed without a Firecrawl account)"
    PASS=0
  else
    echo "  [OK]   skill: $f (absent - core-only skill, as expected)"
  fi
done
if [ -e "$SKILL_DIR/SKILL-core.md" ]; then
  echo "  [FAIL] skill: SKILL-core.md leaked into the installed skill"
  PASS=0
else
  echo "  [OK]   skill: SKILL-core.md not present (as expected)"
fi

# verify the skill files are identical to the target's local-web-search copies
for f in $SKILL_FILES; do
  if cmp -s "$SKILL_DIR/$f" "$TGT_DIR/local-web-search/$f"; then
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
if [ "$(cat "$TGT_DIR/local-web-search/install-dir.txt" 2>/dev/null)" = "$TGT_DIR" ]; then
  echo "  [OK]   bundled install-dir.txt -> $TGT_DIR"
else
  echo "  [FAIL] bundled install-dir.txt is wrong: $(cat "$TGT_DIR/local-web-search/install-dir.txt" 2>/dev/null)"
  PASS=0
fi

# --- verify the hint actually works: run config.py's finder standalone ------
"$PY" - "$TGT_DIR" <<'PYEOF'
import sys, os
expected = sys.argv[1]
# Simulate the skill being run from ~/.agents/skills/local-web-search/scripts
sys.path.insert(0, os.path.expanduser("~/.agents/skills/local-web-search/scripts"))
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
sys.path.insert(0, os.path.expanduser("~/.agents/skills/local-web-search/scripts"))
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

# --- verify the core Firecrawl tool scripts resolve the LOCAL endpoints ------
"$PY" - <<'PYEOF'
import sys, os
sys.path.insert(0, os.path.expanduser("~/.agents/skills/local-web-search/scripts"))
import firecrawl_api as fc
if fc.base_url().endswith(":9991") and fc.is_local():
    print("  [OK]   firecrawl_api.base_url = %s (local stack)" % fc.base_url())
else:
    print("  [FAIL] firecrawl_api.base_url = %s" % fc.base_url())
    sys.exit(1)
if fc.auth_headers().get("Authorization") is None:
    print("  [OK]   no Bearer key in core mode (local stack, no account)")
else:
    print("  [FAIL] unexpected Authorization header in core mode")
    sys.exit(1)
checks = [
    ("web_map",          "/v1/map"),
    ("web_crawl",        "/v1/crawl"),
    ("web_crawl_status", "/v1/crawl"),
]
for name, suffix in checks:
    mod = __import__(name)
    endpoint = mod.ENDPOINT
    if endpoint.endswith(":9991" + suffix):
        print("  [OK]   %s.ENDPOINT = %s" % (name, endpoint))
    else:
        print("  [FAIL] %s.ENDPOINT = %s (expected suffix %s)" % (name, endpoint, suffix))
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

# --- account-mode install: a Firecrawl account installs all 24 tools ------
echo
echo "===== account-mode install: fake Firecrawl account -> all 24 tools ====="

TGT3="$TESTROOT/target3"
# answers: target, searxng port, firecrawl port, LLM? -> n,
#          account? -> y, key, URL (Enter = default), confirm -> y
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$TGT3" "" "" "n" "y" "fc-e2e-test-key-123" "" "y" \
  | "$SRC_DIR/install-local-search.sh" > "$TESTROOT/inst3.log" 2>&1
RC3=$?
echo "Installer exit code: $RC3"
tail -20 "$TESTROOT/inst3.log"
echo "--------------------------------"

if [ "$RC3" = 0 ] \
   && grep -q "Installing the local-web-search agent skill" "$TESTROOT/inst3.log" \
   && ! grep -q "core-only" "$TESTROOT/inst3.log"; then
  echo "  [OK]   account-mode install completed (no core-only trim)"
else
  echo "  [FAIL] account-mode install"; PASS=0
fi

if grep -q "^FIRECRAWL_API_URL=https://api.firecrawl.dev$" "$TGT3/.env" \
   && grep -q "^FIRECRAWL_API_KEY=fc-e2e-test-key-123$" "$TGT3/.env"; then
  echo "  [OK]   .env holds the account credentials"
else
  echo "  [FAIL] .env is missing the account credentials"; PASS=0
fi

if grep -q "web_monitor_create" "$SKILL_DIR/SKILL.md" \
   && ! grep -q "5 tools: search, scrape, map, crawl, crawl status" "$SKILL_DIR/SKILL.md" \
   && [ ! -e "$SKILL_DIR/SKILL-core.md" ] \
   && [ ! -e "$TGT3/local-web-search/SKILL-core.md" ]; then
  echo "  [OK]   SKILL.md is the full 24-tool variant (SKILL-core.md cleaned up)"
else
  echo "  [FAIL] SKILL.md variant wrong in account mode"; PASS=0
fi

ALL_SKILL_FILES="SKILL.md scripts/config.py scripts/ensure_stack.py scripts/firecrawl_api.py \
         scripts/web_search.py scripts/web_scrape.py scripts/web_map.py \
         scripts/web_crawl.py scripts/web_crawl_status.py scripts/web_agent.py \
         scripts/web_agent_status.py scripts/web_interact.py \
         scripts/web_interact_stop.py scripts/web_parse.py \
         scripts/web_monitor_create.py scripts/web_monitor_list.py \
         scripts/web_monitor_get.py scripts/web_monitor_update.py \
         scripts/web_monitor_delete.py scripts/web_monitor_run.py \
         scripts/web_monitor_checks.py scripts/web_monitor_check.py \
         scripts/web_research_search.py scripts/web_research_inspect.py \
         scripts/web_research_related.py scripts/web_research_read.py \
         scripts/web_github_search.py scripts/web_developer_search.py"
ACCOUNT_PASS=1
for f in $ALL_SKILL_FILES; do
  if [ -s "$SKILL_DIR/$f" ]; then :; else
    echo "  [FAIL] account-mode skill missing: $f"
    ACCOUNT_PASS=0; PASS=0
  fi
done
if [ "$ACCOUNT_PASS" = 1 ]; then
  echo "  [OK]   all 24 tool scripts + shared modules in the account-mode skill"
fi

# --- account-mode: firecrawl_api.py must pick the .env credentials up -------
"$PY" - <<'PYEOF3'
import sys, os
sys.path.insert(0, os.path.expanduser("~/.agents/skills/local-web-search/scripts"))
for var in ("LOCAL_SEARCH_DIR", "FIRECRAWL_API_URL", "FIRECRAWL_API_KEY"):
    os.environ.pop(var, None)
import firecrawl_api as fc
if fc.base_url() == "https://api.firecrawl.dev":
    print("  [OK]   firecrawl_api.base_url() reads FIRECRAWL_API_URL from the install .env")
else:
    print("  [FAIL] firecrawl_api.base_url() = %s" % fc.base_url()); sys.exit(1)
if not fc.is_local():
    print("  [OK]   firecrawl_api.is_local() is False (remote account mode)")
else:
    print("  [FAIL] firecrawl_api.is_local() should be False in account mode"); sys.exit(1)
hdrs = fc.auth_headers()
if hdrs.get("Authorization") == "Bearer fc-e2e-test-key-123":
    print("  [OK]   auth_headers() carries the Bearer key from the install .env")
else:
    print("  [FAIL] Authorization header wrong: %r" % hdrs.get("Authorization")); sys.exit(1)
PYEOF3
[ $? = 0 ] || PASS=0

# --- account-mode: every tool script routes to the cloud API ---------------
"$PY" - <<'PYEOF4'
import sys, os
sys.path.insert(0, os.path.expanduser("~/.agents/skills/local-web-search/scripts"))
for var in ("LOCAL_SEARCH_DIR", "FIRECRAWL_API_URL", "FIRECRAWL_API_KEY"):
    os.environ.pop(var, None)
checks = [
    ("web_map",              "/v1/map"),
    ("web_crawl",            "/v1/crawl"),
    ("web_crawl_status",     "/v1/crawl"),
    ("web_agent",            "/v1/agent"),
    ("web_agent_status",     "/v1/agent"),
    ("web_interact",         "/v1/interact"),
    ("web_interact_stop",    "/v1/interact"),
    ("web_parse",            "/v1/parse"),
    ("web_monitor_create",   "/v1/monitor"),
    ("web_monitor_list",     "/v1/monitor"),
    ("web_monitor_get",      "/v1/monitor"),
    ("web_monitor_update",   "/v1/monitor"),
    ("web_monitor_delete",   "/v1/monitor"),
    ("web_monitor_run",      "/v1/monitor"),
    ("web_monitor_checks",   "/v1/monitor"),
    ("web_monitor_check",    "/v1/monitor"),
    ("web_research_search",  "/v1/research/search/papers"),
    ("web_research_inspect", "/v1/research/papers"),
    ("web_research_related", "/v1/research/related"),
    ("web_research_read",    "/v1/research/papers"),
    ("web_github_search",    "/v1/research/search/github"),
    ("web_developer_search", "/v1/developer/search"),
]
for name, suffix in checks:
    mod = __import__(name)
    endpoint = mod.ENDPOINT
    if endpoint.startswith("https://api.firecrawl.dev") and endpoint.endswith(suffix):
        print("  [OK]   %s.ENDPOINT = %s" % (name, endpoint))
    else:
        print("  [FAIL] %s.ENDPOINT = %s (expected cloud API + %s)" % (name, endpoint, suffix))
        sys.exit(1)
print("  [OK]   all 22 Firecrawl tool scripts route to the cloud API")
PYEOF4
[ $? = 0 ] || PASS=0

# --- docker auto-start test: engine down -> installer starts it ----------
echo
echo "===== docker auto-start test: installer boots a down engine ====="

# mock docker #4: engine DOWN until a mock 'systemctl start' flips it up
mkdir -p "$TESTROOT/bin4"
cat > "$TESTROOT/bin4/docker" <<'MOCK4'
#!/usr/bin/env bash
case "$1" in
  info)
    [ -f "$DOCKER_UP_MARKER" ] && exit 0
    exit 1 ;;
  compose)
    case "$2" in
      version) echo "Docker Compose version v2.0.0-test"; exit 0 ;;
      *) echo "[mock] ok"; exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
MOCK4
cat > "$TESTROOT/bin4/systemctl" <<'MOCK4S'
#!/usr/bin/env bash
# mock systemd control: 'start <unit>' brings the engine up
[ "$1" = "start" ] && : > "$DOCKER_UP_MARKER"
exit 0
MOCK4S
chmod +x "$TESTROOT/bin4/docker" "$TESTROOT/bin4/systemctl"

TGT2="$TESTROOT/target2"
UPMARK="$TESTROOT/docker_up.marker"
printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$TGT2" "" "" "n" "n" "y" \
  | env DOCKER_UP_MARKER="$UPMARK" PATH="$TESTROOT/bin4:$PATH" \
    "$SRC_DIR/install-local-search.sh" > "$TESTROOT/instD.log" 2>&1
DRC=$?
if [ "$DRC" = 0 ] && grep -q "trying to start it" "$TESTROOT/instD.log" \
   && grep -q "Launched Docker in the background" "$TESTROOT/instD.log" \
   && grep -q "engine is online" "$TESTROOT/instD.log" \
   && [ -f "$UPMARK" ] && [ -s "$TGT2/docker-compose.yml" ]; then
  echo "  [OK]   auto-start: installer launched the engine, waited, finished"
else
  echo "  [FAIL] docker auto-start install"; tail -20 "$TESTROOT/instD.log"; PASS=0
fi

# mock docker #5: engine down and NOTHING can start it -> clean failure
mkdir -p "$TESTROOT/bin5"
cat > "$TESTROOT/bin5/docker" <<'MOCK5'
#!/usr/bin/env bash
case "$1" in
  info) exit 1 ;;
  *) exit 0 ;;
esac
MOCK5
chmod +x "$TESTROOT/bin5/docker"
for m in systemctl service sudo; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TESTROOT/bin5/$m"
  chmod +x "$TESTROOT/bin5/$m"
done
printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$TESTROOT/target5" "" "" "n" "n" "y" \
  | env PATH="$TESTROOT/bin5:$PATH" "$SRC_DIR/install-local-search.sh" \
    > "$TESTROOT/instD2.log" 2>&1
D2RC=$?
if [ "$D2RC" != 0 ] \
   && grep -q "Could not start the Docker engine" "$TESTROOT/instD2.log"; then
  echo "  [OK]   auto-start failure: clean error + exit 1 when nothing can start it"
else
  echo "  [FAIL] expected clean failure when the engine cannot be started"
  tail -20 "$TESTROOT/instD2.log"; PASS=0
fi

# mock docker #6: systemctl 'starts' the engine but docker info never works
mkdir -p "$TESTROOT/bin6"
cp "$TESTROOT/bin5/docker" "$TESTROOT/bin6/docker"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTROOT/bin6/systemctl"
chmod +x "$TESTROOT/bin6/docker" "$TESTROOT/bin6/systemctl"
printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$TESTROOT/target6" "" "" "n" "n" "y" \
  | env LOCAL_SEARCH_DOCKER_TIMEOUT=2 PATH="$TESTROOT/bin6:$PATH" \
    "$SRC_DIR/install-local-search.sh" > "$TESTROOT/instD3.log" 2>&1
D3RC=$?
if [ "$D3RC" != 0 ] && grep -q "did not come online" "$TESTROOT/instD3.log"; then
  echo "  [OK]   engine-wait timeout: clean error after LOCAL_SEARCH_DOCKER_TIMEOUT"
else
  echo "  [FAIL] expected timeout failure when the engine never comes online"
  tail -20 "$TESTROOT/instD3.log"; PASS=0
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
if [ -f "$TGT_DIR/.env" ] && [ -d "$TGT_DIR/local-web-search" ]; then
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
# result (incl. the local-web-search skill). Needs: unzip + python3.
# Any pre-existing ~/.agents/skills/local-web-search is backed up and restored.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
ZIP="$ROOT/local-search.zip"
TESTROOT="$ROOT/.zip-test-$$"
SKILL_DIR="$HOME/.agents/skills/local-web-search"
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
# answers: target, searxng port, firecrawl port, LLM? -> n,
#          Firecrawl account? -> n (core-only default), confirm -> y
TGT="$TESTROOT/installed"
printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$TGT" "" "" "n" "n" "y" \
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
         local-web-search/SKILL.md \
         local-web-search/scripts/config.py local-web-search/scripts/ensure_stack.py \
         local-web-search/scripts/web_search.py local-web-search/scripts/web_scrape.py \
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

# core-only default: no account-gated tools, core SKILL.md, no leaked variant
if [ -e "$TGT/local-web-search/scripts/web_agent.py" ] \
   || [ -e "$TGT/local-web-search/scripts/web_monitor_create.py" ] \
   || [ -e "$TGT/local-web-search/SKILL-core.md" ]; then
  echo "[FAIL] account-gated tools (or SKILL-core.md) installed in core mode"; PASS=0
else
  echo "[OK] core-only skill: account-gated tools skipped, no SKILL-core.md"
fi
if grep -q "5 tools: search, scrape, map, crawl, crawl status" "$TGT/local-web-search/SKILL.md"; then
  echo "[OK] SKILL.md is the core-only variant"
else
  echo "[FAIL] SKILL.md is not the core-only variant"; PASS=0
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
         local-web-search/SKILL.md local-web-search/SKILL-core.md \
         local-web-search/scripts/config.py local-web-search/scripts/ensure_stack.py \
         local-web-search/scripts/web_search.py local-web-search/scripts/web_scrape.py; do
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
  ...                          ← 44 source files (compose, scripts, skill, docs)
gen_installers.py              reads local-search/ → writes the two installers
gen_rig.py                     reads local-search/ + this rig → writes the two packers
extract-embedded.py            pull all embedded files out of any single .sh artifact
test_b64.py                    every file embedded in the .bat installer round-trips
test_heredocs.py               every file embedded in the .sh installer matches
test_rig.py                    both rig packers embed the current files exactly
e2e_test.sh                    install → skill → self-heal → account mode → docker auto-start → uninstall (mocked docker + fake stack)
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
# from the rig packer: recovers the COMPLETE rig (57 files)
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
  `~/.agents/skills/local-web-search` if you have a real install — they never
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
REM    * the local-search source tree (44 files)
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
echo   Will unpack 56 files into: !TARGET!
set "CONFIRM="
set /p CONFIRM="Proceed? [Y/n]: "
if /i "!CONFIRM!"=="n" ( echo Cancelled. & pause & exit /b 0 )

if not exist "!TARGET!" mkdir "!TARGET!"
if not exist "!TARGET!\local-search" mkdir "!TARGET!\local-search"
if not exist "!TARGET!\local-search\config\searxng" mkdir "!TARGET!\local-search\config\searxng"
if not exist "!TARGET!\local-search\local-web-search\scripts" mkdir "!TARGET!\local-search\local-web-search\scripts"

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
>> "!B64TMP!" echo LWVtYmVkLXRleHQKCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KIyAgT3B0aW9uYWw6IEZpcmVjcmF3
>> "!B64TMP!" echo bCBhY2NvdW50IChwYWlkIGNsb3VkIHNlcnZpY2UpIGZvciB0aGUgYWNjb3VudC1vbmx5CiMgIGxv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2ggdG9vbHMgKHJlc2VhcmNoIGFnZW50LCBpbnRlcmFjdCwgcGFyc2UsIG1v
>> "!B64TMP!" echo bml0b3JzLCBwYXBlcgojICByZXNlYXJjaCwgR2l0SHViL2RldmVsb3BlciBzZWFyY2gpLgojCiMg
>> "!B64TMP!" echo IFRoZSBpbnN0YWxsZXIgb2ZmZXJzIHRvIHdyaXRlIHRoZXNlIGZvciB5b3UgKGFuc3dlciAneScg
>> "!B64TMP!" echo YXQgdGhlCiMgICJBZGQgYSBGaXJlY3Jhd2wgYWNjb3VudD8iIHF1ZXN0aW9uLCB0aGVuIHBhc3Rl
>> "!B64TMP!" echo IHlvdXIga2V5KS4gV2l0aG91dCB0aGVtCiMgIHRoZSBpbnN0YWxsZXIgc2tpcHMgdGhvc2UgdG9v
>> "!B64TMP!" echo bHMgYW5kIGluc3RhbGxzIG9ubHkgdGhlIGZyZWUgbG9jYWwgb25lcy4KIyAgVGhlIGxvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2ggc2NyaXB0cyByZWFkIHRoZXNlIGtleXMgZnJvbSBUSElTIGZpbGU7CiMgIEZJUkVD
>> "!B64TMP!" echo UkFXTF9BUElfVVJMIC8gRklSRUNSQVdMX0FQSV9LRVkgZW52aXJvbm1lbnQgdmFyaWFibGVzIG92
>> "!B64TMP!" echo ZXJyaWRlIHRoZW0uCiMgIChUaGUgRG9ja2VyIGNvbnRhaW5lcnMgaWdub3JlIHRoZXNlIGtleXMg
>> "!B64TMP!" echo ZW50aXJlbHkuKQojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgRklSRUNSQVdMX0FQSV9VUkw9aHR0
>> "!B64TMP!" echo cHM6Ly9hcGkuZmlyZWNyYXdsLmRldgojIEZJUkVDUkFXTF9BUElfS0VZPWZjLXlvdXIta2V5LWhl
>> "!B64TMP!" echo cmUK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\.env.example"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/README.md ---
set "B64TMP=%TEMP%\LSR1940939601.b64"
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
>> "!B64TMP!" echo LCBGaXJlY3Jhd2wgcG9ydCwgKG9wdGlvbmFsbHkpIGEgbG9jYWwgTExNLCBhbmQKKG9wdGlvbmFs
>> "!B64TMP!" echo bHkpIGEgRmlyZWNyYXdsIGFjY291bnQg4oCUIHdpdGggc2Vuc2libGUgZGVmYXVsdHMgeW91IGNh
>> "!B64TMP!" echo biBhY2NlcHQgYnkKcHJlc3NpbmcgKipFbnRlcioqLiBJdCB0aGVuIGdlbmVyYXRlcyBjcnlwdG9n
>> "!B64TMP!" echo cmFwaGljYWxseS1zZWN1cmUgY3JlZGVudGlhbHMsCndyaXRlcyB5b3VyIGAuZW52YCwgKippbnN0
>> "!B64TMP!" echo YWxscyB0aGUgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCoqLCBwdWxscyB0aGUKaW1hZ2VzLCBhbmQg
>> "!B64TMP!" echo c3RhcnRzIHRoZSBzdGFjay4KCj4gKipEb2NrZXIgaXNuJ3QgcnVubmluZz8qKiBObyBwcm9ibGVt
>> "!B64TMP!" echo IOKAlCB0aGUgaW5zdGFsbGVyIHN0YXJ0cyBpdCBmb3IgeW91OiBpdAo+IGxhdW5jaGVzIERvY2tl
>> "!B64TMP!" echo ciBEZXNrdG9wIChXaW5kb3dzL21hY09TKSBvciB0aGUgRG9ja2VyIHNlcnZpY2UKPiAoYHN5c3Rl
>> "!B64TMP!" echo bWN0bGAvYHNlcnZpY2VgLCBMaW51eCkgYW5kIHdhaXRzIHVwIHRvIDUgbWludXRlcyBmb3IgdGhl
>> "!B64TMP!" echo IGVuZ2luZSB3aGlsZQo+IHlvdSBhbnN3ZXIgdGhlIHByb21wdHMuIChPdmVycmlkZSB0aGUgd2Fp
>> "!B64TMP!" echo dCB3aXRoIHRoZQo+IGBMT0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVRgIGVudiB2YXIsIGluIHNl
>> "!B64TMP!" echo Y29uZHMuKQoKIyMjIFdpbmRvd3MKCjEuIEluc3RhbGwgW0RvY2tlciBEZXNrdG9wXShodHRwczov
>> "!B64TMP!" echo L3d3dy5kb2NrZXIuY29tL3Byb2R1Y3RzL2RvY2tlci1kZXNrdG9wLykg4oCUIG5vIG5lZWQgdG8g
>> "!B64TMP!" echo b3BlbiBpdCBmaXJzdDsgdGhlIGluc3RhbGxlciBsYXVuY2hlcyBpdCBhdXRvbWF0aWNhbGx5Lgoy
>> "!B64TMP!" echo LiBEb3VibGUtY2xpY2sgKipgaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0YCoqIChvciBydW4gaXQg
>> "!B64TMP!" echo ZnJvbSBhIHRlcm1pbmFsKS4KCmBgYAotLS0gU3RlcCAxIG9mIDU6IEluc3RhbGwgbG9jYXRpb24g
>> "!B64TMP!" echo LS0tLS0tLS0tLQogIFRhcmdldCBmb2xkZXIgW3ByZXNzIEVudGVyIGZvciBkZWZhdWx0XTogICAg
>> "!B64TMP!" echo ICAgICAgICAjIEM6XFVzZXJzXFlvdVxsb2NhbC1zZWFyY2gKLS0tIFN0ZXAgMiBvZiA1OiBTZWFy
>> "!B64TMP!" echo WE5HIHBvcnQgKGRlZmF1bHQgOTk5MCkgLS0tLS0tCiAgUG9ydCBmb3IgU2VhclhORyBbcHJlc3Mg
>> "!B64TMP!" echo RW50ZXIgZm9yIDk5OTBdOiA5OTkwCi0tLSBTdGVwIDMgb2YgNTogRmlyZWNyYXdsIHBvcnQgKGRl
>> "!B64TMP!" echo ZmF1bHQgOTk5MSkgLS0tLQogIFBvcnQgZm9yIEZpcmVjcmF3bCBbcHJlc3MgRW50ZXIgZm9yIDk5
>> "!B64TMP!" echo OTFdOiA5OTkxCi0tLSBTdGVwIDQgb2YgNTogTG9jYWwgTExNIChvcHRpb25hbCkgLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLQogIENvbm5lY3QgYSBsb2NhbCBMTE0gbm93PyBbeS9OXTogICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICMgb3B0aW9uYWwsIHNlZSBzZWN0aW9uIEQKLS0tIFN0ZXAgNSBvZiA1OiBGaXJlY3Jhd2wg
>> "!B64TMP!" echo YWNjb3VudCAob3B0aW9uYWwpIC0tLS0tCiAgQWRkIGEgRmlyZWNyYXdsIGFjY291bnQgbm93PyBb
>> "!B64TMP!" echo eS9OXTogbiAgICAgICAgICAgICAgICAgIyBkZWZhdWx0OiBza2lwLCBzZWUgYmVsb3cKYGBgCgoj
>> "!B64TMP!" echo IyMgTGludXggJiBtYWNPUwoKYGBgYmFzaApjaG1vZCAreCBpbnN0YWxsLWxvY2FsLXNlYXJjaC5z
>> "!B64TMP!" echo aAouL2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoCmBgYAoKVGhlIHByb21wdHMgYXJlIHRoZSBzYW1l
>> "!B64TMP!" echo LiBEZWZhdWx0czogaW5zdGFsbCB0byBgfi9sb2NhbC1zZWFyY2hgLCBTZWFyWE5HIG9uCmA5OTkw
>> "!B64TMP!" echo YCwgRmlyZWNyYXdsIG9uIGA5OTkxYCwgbm8gRmlyZWNyYXdsIGFjY291bnQuIEEgc3RvcHBlZCBE
>> "!B64TMP!" echo b2NrZXIgZW5naW5lCmlzIHN0YXJ0ZWQgYXV0b21hdGljYWxseSAoRG9ja2VyIERlc2t0b3Agb24g
>> "!B64TMP!" echo bWFjT1MsIGBzeXN0ZW1jdGxgL2BzZXJ2aWNlYCBvbgpMaW51eCkuCgo+ICoqVGhlIG9wdGlvbmFs
>> "!B64TMP!" echo IEZpcmVjcmF3bCBhY2NvdW50IChTdGVwIDUpLioqIEEgZmV3IG9mIHRoZSBidW5kbGVkIHNraWxs
>> "!B64TMP!" echo J3MKPiB0b29scyDigJQgdGhlIHJlc2VhcmNoIGFnZW50LCBsaXZlLXBhZ2UgYGludGVyYWN0YCwg
>> "!B64TMP!" echo ZmlsZSBgcGFyc2VgLCBtb25pdG9ycywKPiBwYXBlciByZXNlYXJjaCwgYW5kIEdpdEh1Yi9kZXZl
>> "!B64TMP!" echo bG9wZXIgc2VhcmNoIOKAlCBvbmx5IHdvcmsgYWdhaW5zdCBGaXJlY3Jhd2wncwo+IHBhaWQgY2xv
>> "!B64TMP!" echo dWQgQVBJLiBUaGUgZGVmYXVsdCBhbnN3ZXIgaXMgKipOKio6IHRob3NlIHRvb2xzIGFyZSBzaW1w
>> "!B64TMP!" echo bHkgKm5vdAo+IGluc3RhbGxlZCosIGFuZCB0aGUgc2tpbGwgc2hpcHMgYSBsZWFuZXIgYFNLSUxM
>> "!B64TMP!" echo Lm1kYCBjb3ZlcmluZyBqdXN0IHRoZSBmcmVlCj4gbG9jYWwgdG9vbHMuIEFuc3dlciAqKnkqKiBp
>> "!B64TMP!" echo bnN0ZWFkIGFuZCB0aGUgaW5zdGFsbGVyIGFza3MgZm9yIHlvdXIgQVBJIGtleQo+IChhbmQgQVBJ
>> "!B64TMP!" echo IFVSTCwgZGVmYXVsdCBgaHR0cHM6Ly9hcGkuZmlyZWNyYXdsLmRldmApLCBzdG9yZXMgdGhlbSBp
>> "!B64TMP!" echo biB5b3VyCj4gYC5lbnZgLCBhbmQgaW5zdGFsbHMgdGhlIGZ1bGwgMjQtdG9vbCBzZXQuIFlvdSBj
>> "!B64TMP!" echo YW4gY2hhbmdlIHlvdXIgbWluZCBsYXRlcgo+IGJ5IHJlLXJ1bm5pbmcgdGhlIGluc3RhbGxlciBh
>> "!B64TMP!" echo bmQgYW5zd2VyaW5nIGRpZmZlcmVudGx5LgoKPiAqKkZpcnN0IHJ1biBkb3dubG9hZHMgfjPigJM0
>> "!B64TMP!" echo IEdCIG9mIERvY2tlciBpbWFnZXMqKiAodGhlIFBsYXl3cmlnaHQgaW1hZ2UgYnVuZGxlcwo+IGEg
>> "!B64TMP!" echo ZnVsbCBDaHJvbWl1bSkuIFN1YnNlcXVlbnQgc3RhcnRzIGFyZSBhIGZldyBzZWNvbmRzLgoKV2hl
>> "!B64TMP!" echo biBpdCBmaW5pc2hlcyB5b3UnbGwgc2VlOgoKYGBgClNlYXJYTkcgIChzZWFyY2ggKyBKU09OIEFQ
>> "!B64TMP!" echo SSk6ICBodHRwOi8vbG9jYWxob3N0Ojk5OTAKRmlyZWNyYXdsIChzY3JhcGUvY3Jhd2wgQVBJKTog
>> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkxCkFnZW50IHNraWxsOiBDOlxVc2Vyc1xZb3VcLmFnZW50c1xz
>> "!B64TMP!" echo a2lsbHNcbG9jYWwtd2ViLXNlYXJjaCAgIChvciB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gpCmBgYAoKT3BlbiBgaHR0cDovL2xvY2FsaG9zdDo5OTkwYCBpbiBhIGJyb3dzZXIgdG8g
>> "!B64TMP!" echo c2VlIHRoZSBTZWFyWE5HIHNlYXJjaCBVSSDigJQgb3IsCmlmIHlvdXIgYWdlbnQgbG9hZHMgc2tp
>> "!B64TMP!" echo bGxzIGZyb20gYH4vLmFnZW50cy9za2lsbHMvYCwganVzdCBhc2sgaXQgdG8gcmVzZWFyY2gKc29t
>> "!B64TMP!" echo ZXRoaW5nIGN1cnJlbnQgYW5kIGl0IHdpbGwgdXNlICoqbG9jYWwtd2ViLXNlYXJjaCoqIGF1dG9t
>> "!B64TMP!" echo YXRpY2FsbHkgKHNlZQpbc2VjdGlvbiBBXSgjYS10aGUtYnVuZGxlZC1sb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo LXNraWxsLXJlY29tbWVuZGVkKSkuCgotLS0KCiMjIE1hbmFnaW5nIHRoZSBzdGFjawoKQWZ0ZXIg
>> "!B64TMP!" echo aW5zdGFsbCwgdGhlIG1hbmFnZW1lbnQgc2NyaXB0cyBsaXZlICoqaW4geW91ciBpbnN0YWxsIGZv
>> "!B64TMP!" echo bGRlcioqCihgQzpcVXNlcnNcWW91XGxvY2FsLXNlYXJjaGAgb24gV2luZG93cywgYH4vbG9jYWwt
>> "!B64TMP!" echo c2VhcmNoYCBvbiBMaW51eC9tYWNPUykuClRoZXkgYXV0by1kZXRlY3QgdGhlaXIgb3duIGxvY2F0
>> "!B64TMP!" echo aW9uLCBzbyB5b3UgY2FuIHJ1biB0aGVtIGZyb20gYW55d2hlcmUgYnkKZG91YmxlLWNsaWNraW5n
>> "!B64TMP!" echo IG9yIGAuL2AtaW5nIHRoZW0uCgp8IEFjdGlvbiB8IFdpbmRvd3MgfCBMaW51eCAvIG1hY09TIHwK
>> "!B64TMP!" echo fC0tLS0tLS0tfC0tLS0tLS0tLXwtLS0tLS0tLS0tLS0tLS18CnwgKipTdGFydCoqIHRoZSBzdGFj
>> "!B64TMP!" echo ayB8IGBSdW4uYmF0YCB8IGAuL3J1bi5zaGAgfAp8ICoqU3RvcCoqIChrZWVwIGRhdGEpIHwgYFN0
>> "!B64TMP!" echo b3AuYmF0YCB8IGAuL3N0b3Auc2hgIHwKfCAqKlVwZGF0ZSoqIGltYWdlcyArIGFwcGx5IGAuZW52
>> "!B64TMP!" echo YCBjaGFuZ2VzICsgKipyZS1zeW5jIHRoZSBza2lsbCoqIHwgYFVwZGF0ZS5iYXRgIHwgYC4vdXBk
>> "!B64TMP!" echo YXRlLnNoYCB8CnwgKipVbmluc3RhbGwqKiAoY29udGFpbmVycyArIHZvbHVtZXMgKyBza2lsbCwg
>> "!B64TMP!" echo b3B0aW9uYWwgZm9sZGVyIGRlbGV0ZSkgfCBgVW5pbnN0YWxsLmJhdGAgfCBgLi91bmluc3RhbGwu
>> "!B64TMP!" echo c2hgIHwKCi0gKipTdG9wKiogb25seSByZW1vdmVzIGNvbnRhaW5lcnM7IHlvdXIgZGF0YSB2b2x1
>> "!B64TMP!" echo bWVzIChGaXJlY3Jhd2wgam9iIHN0YXRlLAogIHJlZGlzIGNhY2hlLCByYWJiaXRtcS9wb3N0Z3Jl
>> "!B64TMP!" echo cyBkYXRhKSBhcmUgcHJlc2VydmVkLgotICoqVXBkYXRlKiogcnVucyBgZG9ja2VyIGNvbXBvc2Ug
>> "!B64TMP!" echo cHVsbGAgdGhlbiBgZG9ja2VyIGNvbXBvc2UgdXAgLWRgLCBzbyBpdAogIGJvdGggdXBncmFkZXMg
>> "!B64TMP!" echo aW1hZ2VzICoqYW5kKiogYXBwbGllcyBhbnkgcG9ydC9MTE0gZWRpdHMgeW91IG1hZGUgdG8gYC5l
>> "!B64TMP!" echo bnZgOwogIGl0IGFsc28gcmUtY29waWVzIHRoZSBidW5kbGVkIGBsb2NhbC13ZWItc2VhcmNoYCBz
>> "!B64TMP!" echo a2lsbCBpbnRvIGB+Ly5hZ2VudHMvc2tpbGxzL2AuCi0gKipVbmluc3RhbGwqKiBydW5zIGBkb2Nr
>> "!B64TMP!" echo ZXIgY29tcG9zZSBkb3duIC12YCAoZGVsZXRlcyB2b2x1bWVzICsgZGF0YSksCiAgcmVtb3ZlcyB0
>> "!B64TMP!" echo aGUgYGxvY2FsLXdlYi1zZWFyY2hgIHNraWxsIGZyb20gYH4vLmFnZW50cy9za2lsbHMvbG9jYWwt
>> "!B64TMP!" echo d2ViLXNlYXJjaGAsIHRoZW4KICBvcHRpb25hbGx5IGRlbGV0ZXMgdGhlIGluc3RhbGwgZm9sZGVy
>> "!B64TMP!" echo LiBQdWxsZWQgaW1hZ2VzIGFyZSBrZXB0OyByZWNsYWltIHRoZW0KICB3aXRoIGBkb2NrZXIgaW1h
>> "!B64TMP!" echo Z2UgcHJ1bmUgLWFgIGlmIGRlc2lyZWQuCgotLS0KCiMjIEhvdyBpdCBmaXRzIHRvZ2V0aGVyCgpg
>> "!B64TMP!" echo YGAKICAgICAgICB5b3VyIEFJIG1vZGVsIC8gYWdlbnQgKGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwp
>> "!B64TMP!" echo IC8gTUNQIGNsaWVudCAvIGNoYXQgVUkKICAgICAgICAgICAgICAgICAgICAgIOKUggogICDilIzi
>> "!B64TMP!" echo lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilLzi
>> "!B64TMP!" echo lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
>> "!B64TMP!" echo lIDilIDilJAKICAg4pa8ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg4pa8
>> "!B64TMP!" echo Cmh0dHA6Ly9sb2NhbGhvc3Q6OTk5MCAgICAgICAgICAgIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MQog
>> "!B64TMP!" echo ICDilIIgU2VhclhORyAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIgRmlyZWNyYXdsIEFQ
>> "!B64TMP!" echo SQogICDilIIgIC0gL3NlYXJjaD9xPS4uLiZmb3JtYXQ9anNvbiAgICAgICDilIIgIC0gL3YxL3Nj
>> "!B64TMP!" echo cmFwZSAgIChvbmUgVVJMIC0+IG1hcmtkb3duKQogICDilIIgIC0gYWdncmVnYXRlcyB+NzAgZW5n
>> "!B64TMP!" echo aW5lcyAgICAgICAgICAg4pSCICAtIC92MS9jcmF3bCAgICAod2hvbGUgc2l0ZSwgYXN5bmMpCiAg
>> "!B64TMP!" echo IOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIgIC0gL3YxL21hcCAg
>> "!B64TMP!" echo ICAgIChzaXRlIFVSTCB0cmVlKQogICDilIIgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAg4pSCICAtIC92MS9zZWFyY2ggICAoLT4gdXNlcyBTZWFyWE5HISkKICAg4pSCICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOKUgiAgLSAvdjEvZXh0cmFjdCAgKC0+IHVz
>> "!B64TMP!" echo ZXMgeW91ciBMTE0pCiAgIOKUguKXhOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCB3aXJl
>> "!B64TMP!" echo ZCB0b2dldGhlciDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilKQgIFNFQVJYTkdfRU5E
>> "!B64TMP!" echo UE9JTlQ9aHR0cDovL3NlYXJ4bmc6ODA4MAogICDilIIgICAgICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAg4pSCCiAgIOKUlOKUgOKUgOKUgOKUgOKUgOKUgOKUgCBwcml2YXRlIGRvY2tl
>> "!B64TMP!" echo ciBuZXR3b3JrIOKUgOKUgOKUgOKUgOKUgOKUgOKUmAogICAgICAgICAgICAgICAgIGxvY2FsLXNl
>> "!B64TMP!" echo YXJjaC1uZXQKICAgYWxzbyBvbiBpdDogcGxheXdyaWdodC1zZXJ2aWNlIChDaHJvbWl1bSksIHJl
>> "!B64TMP!" echo ZGlzLCByYWJiaXRtcSwgbnVxLXBvc3RncmVzCmBgYAoKVGhyZWUga2V5IHdpcmluZyBkZWNpc2lv
>> "!B64TMP!" echo bnMgdGhlIGluc3RhbGxlciBtYWtlcyBmb3IgeW91OgoKMS4gKipTZWFyWE5HIEpTT04gKyBubyBs
>> "!B64TMP!" echo aW1pdGVyKiog4oCUIGBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55bWxgIHNldHMKICAgYHNlYXJj
>> "!B64TMP!" echo aC5mb3JtYXRzOiBbaHRtbCwganNvbl1gIGFuZCBgc2VydmVyLmxpbWl0ZXI6IGZhbHNlYCwgc28g
>> "!B64TMP!" echo bW9kZWxzIGNhbiBoaXQKICAgYC9zZWFyY2g/Zm9ybWF0PWpzb25gIHdpdGhvdXQgYmVpbmcgYmxv
>> "!B64TMP!" echo Y2tlZCBhcyBhIGJvdC4KMi4gKipGaXJlY3Jhd2wg4oaSIFNlYXJYTkcqKiDigJQgdGhlIEZpcmVj
>> "!B64TMP!" echo cmF3bCBjb250YWluZXIgc2V0cwogICBgU0VBUlhOR19FTkRQT0lOVD1odHRwOi8vc2VhcnhuZzo4
>> "!B64TMP!" echo MDgwYCwgc28gRmlyZWNyYXdsJ3MgYC92MS9zZWFyY2hgIHVzZXMgeW91cgogICBsb2NhbCBTZWFy
>> "!B64TMP!" echo WE5HIGluc3RlYWQgb2YgbmVlZGluZyBhIHRoaXJkLXBhcnR5IHNlYXJjaCBwcm92aWRlci4KMy4g
>> "!B64TMP!" echo Kipsb2NhbC13ZWItc2VhcmNoIHNraWxsIGF1dG8taW5zdGFsbCoqIOKAlCB0aGUgaW5zdGFsbGVy
>> "!B64TMP!" echo IGNvcGllcyB0aGUgYnVuZGxlZCBza2lsbCB0bwogICBgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13
>> "!B64TMP!" echo ZWItc2VhcmNoL2AgKGFkZC9vdmVycmlkZSkgYW5kIHJlY29yZHMgdGhlIGluc3RhbGwgcGF0aCBp
>> "!B64TMP!" echo bgogICBhbiBgaW5zdGFsbC1kaXIudHh0YCBoaW50IGluc2lkZSB0aGUgc2tpbGwsIHNvIHRoZSBz
>> "!B64TMP!" echo a2lsbCBmaW5kcyB0aGUgc3RhY2sgZXZlbgogICBpZiB5b3UgaW5zdGFsbGVkIHRvIGEgY3VzdG9t
>> "!B64TMP!" echo IGZvbGRlciBhbmQgRG9ja2VyIGlzbid0IHJ1bm5pbmcgeWV0LiBXaXRob3V0IGEKICAgY29uZmln
>> "!B64TMP!" echo dXJlZCBGaXJlY3Jhd2wgYWNjb3VudCBpdCBpbnN0YWxscyBvbmx5IHRoZSBmcmVlIGxvY2FsIHRv
>> "!B64TMP!" echo b2xzIGFuZCBhCiAgIG1hdGNoaW5nIGNvcmUtb25seSBgU0tJTEwubWRgLgoKLS0tCgojIyBVc2lu
>> "!B64TMP!" echo ZyBpdCB3aXRoIEFJIG1vZGVscwoKVGhlcmUgYXJlICoqc2V2ZW4qKiB3YXlzIHRvIHVzZSB0aGlz
>> "!B64TMP!" echo IHN5c3RlbSwgZnJvbSBsb3dlc3QgdG8gaGlnaGVzdAppbnRlZ3JhdGlvbi4gUGljayB3aGF0IGZp
>> "!B64TMP!" echo dHMgeW91ciBzdGFjayDigJQgeW91IGNhbiBtaXggYW5kIG1hdGNoLgoKIyMjIEEuIFRoZSBidW5k
>> "!B64TMP!" echo bGVkIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwgKHJlY29tbWVuZGVkKQoKVGhlIGluc3RhbGxlciBz
>> "!B64TMP!" echo aGlwcyB3aXRoICoqbG9jYWwtd2ViLXNlYXJjaCoqLCBhbiBhZ2VudCBza2lsbCB0aGF0IHR1cm5z
>> "!B64TMP!" echo IGFueQpza2lsbC1sb2FkaW5nIGFnZW50IGludG8gYSB3ZWIgcmVzZWFyY2hlciB3aXRoIHplcm8g
>> "!B64TMP!" echo Y29uZmlndXJhdGlvbi4gSWYgeW91cgphZ2VudCByZWFkcyBza2lsbHMgZnJvbSBgfi8uYWdlbnRz
>> "!B64TMP!" echo L3NraWxscy9gCihgQzpcVXNlcnNcWW91XC5hZ2VudHNcc2tpbGxzXGAgb24gV2luZG93cyksIGl0
>> "!B64TMP!" echo J3MgYWxyZWFkeSBhdmFpbGFibGUgYWZ0ZXIKaW5zdGFsbCDigJQgcmVzdGFydCB0aGUgYWdlbnQg
>> "!B64TMP!" echo aWYgaXQgd2FzIHJ1bm5pbmcuCgpUaGUgaW5zdGFsbGVyOgotIHB1dHMgYSBjb3B5IGluIGA8aW5z
>> "!B64TMP!" echo dGFsbCBmb2xkZXI+L2xvY2FsLXdlYi1zZWFyY2gvYCwgYW5kCi0gKiphdXRvbWF0aWNhbGx5IGlu
>> "!B64TMP!" echo c3RhbGxzIChhZGQvb3ZlcnJpZGUpKiogaXQgaW50bwogIGB+Ly5hZ2VudHMvc2tpbGxzL2xvY2Fs
>> "!B64TMP!" echo LXdlYi1zZWFyY2gvYC4KCldoYXQgdGhlIHNraWxsIGRvZXMgZm9yIHRoZSBhZ2VudDoKCi0gKipG
>> "!B64TMP!" echo aW5kcyB0aGUgc3RhY2sgYXV0b21hdGljYWxseS4qKiBJdCByZWFkcyB0aGUgcmVhbCBwb3J0cyBm
>> "!B64TMP!" echo cm9tIHlvdXIgYC5lbnZgCiAgKHNvIGN1c3RvbSBpbnN0YWxsLXRpbWUgcG9ydHMganVzdCB3b3Jr
>> "!B64TMP!" echo KSBhbmQgbG9jYXRlcyB0aGUgaW5zdGFsbCBmb2xkZXIgdmlhCiAgdGhlIGNvbXBvc2UgbGFiZWxz
>> "!B64TMP!" echo IG9uIHRoZSBydW5uaW5nIGNvbnRhaW5lcnMsIHRoZSBpbnN0YWxsZXItcmVjb3JkZWQKICBgaW5z
>> "!B64TMP!" echo dGFsbC1kaXIudHh0YCBoaW50LCBvciBgfi9sb2NhbC1zZWFyY2hgIOKAlCBubyBoYXJkY29kZWQg
>> "!B64TMP!" echo YW55dGhpbmcuCi0gKipTZWxmLWhlYWxzIGEgZG93biBzdGFjayDigJQgbm8gd2FybS11cCBzdGVw
>> "!B64TMP!" echo LioqIElmIHRoZSBEb2NrZXIgZW5naW5lIG9yIHRoZQogIGNvbnRhaW5lcnMgYXJlIGRvd24gd2hl
>> "!B64TMP!" echo biBhIHNlYXJjaC9zY3JhcGUgcnVucywgdGhlIHNjcmlwdCBib290cyB0aGUgZW5naW5lCiAgKERv
>> "!B64TMP!" echo Y2tlciBEZXNrdG9wIC8gYHN5c3RlbWN0bCBzdGFydCBkb2NrZXJgKSwgcnVucyB0aGUgc2FtZSBg
>> "!B64TMP!" echo ZG9ja2VyIGNvbXBvc2UKICB1cCAtZGAgdGhhdCBgUnVuLmJhdGAgLyBgcnVuLnNoYCB1c2UsIHdh
>> "!B64TMP!" echo aXRzIGZvciB0aGUgZW5kcG9pbnRzLCBhbmQgcmV0cmllcwogIHRoZSByZXF1ZXN0IOKAlCBzbyB0
>> "!B64TMP!" echo aGUgYWdlbnQgY2FsbHMgdGhlIHNlYXJjaC9zY3JhcGUgc2NyaXB0cyBkaXJlY3RseSwgZXZlbgog
>> "!B64TMP!" echo IGluIGFuIG9sZCBjb252ZXJzYXRpb24gd2hlcmUgdGhlIHN0YWNrIGhhcyBzaW5jZSBnb25lIGRv
>> "!B64TMP!" echo d24KICAoYGVuc3VyZV9zdGFjay5weWAgcmVtYWlucyBhdmFpbGFibGUgYXMgYW4gb3B0aW9uYWwg
>> "!B64TMP!" echo cHJlLWZsaWdodCBjaGVjaykuIFRoZQogIHN0YWNrIGlzICoqbmV2ZXIgc3RvcHBlZCoqIGJ5IHRo
>> "!B64TMP!" echo ZSBzY3JpcHRzIChzdG9wcGluZyBpcyB5b3VyIGpvYiwgdmlhCiAgYFN0b3AuYmF0YCAvIGBzdG9w
>> "!B64TMP!" echo LnNoYCkuCi0gKipTZWFyY2hlcyB0aGUgd2ViLioqIGB3ZWJfc2VhcmNoLnB5ICJxdWVyeSJgIHBy
>> "!B64TMP!" echo aW50cyB0aGUgdG9wIHJlc3VsdHMgYXMKICBgdGl0bGUgLyB1cmwgLyBzbmlwcGV0YCwgd2l0aCBg
>> "!B64TMP!" echo LS1saW1pdGAsIGAtLXRpbWUtcmFuZ2UgZGF5fHdlZWt8bW9udGhgLCBhbmQKICBgLS1jYXRlZ29y
>> "!B64TMP!" echo aWVzIGl0LG5ld3MsZ2VuZXJhbGAgb3B0aW9ucy4KLSAqKlJlYWRzIHBhZ2VzLioqIGB3ZWJfc2Ny
>> "!B64TMP!" echo YXBlLnB5IDx1cmw+YCByZXR1cm5zIHRoZSBwYWdlIGFzIGNsZWFuIE1hcmtkb3duCiAgKHRydW5j
>> "!B64TMP!" echo YXRlZCBhdCAyMCwwMDAgY2hhcnM7IHJhaXNlIHdpdGggYC0tbWF4LWNoYXJzYCkuCi0gKipFeHBv
>> "!B64TMP!" echo c2VzIHRoZSBmdWxsIEZpcmVjcmF3bCBNQ1Agc3VyZmFjZSDigJQgMjQgdG9vbHMuKiogQmVzaWRl
>> "!B64TMP!" echo cyBzZWFyY2ggYW5kCiAgc2NyYXBlLCB0aGUgc2tpbGwgc2hpcHMgc2NyaXB0cyBtaXJyb3Jpbmcg
>> "!B64TMP!" echo ZXZlcnkgRmlyZWNyYXdsIE1DUCB0b29sOgogIGB3ZWJfbWFwLnB5YCAoZW51bWVyYXRlIGEgc2l0
>> "!B64TMP!" echo ZSdzIFVSTHMpLCBgd2ViX2NyYXdsLnB5YCAvCiAgYHdlYl9jcmF3bF9zdGF0dXMucHlgIChtdWx0
>> "!B64TMP!" echo aS1wYWdlIGNyYXdscyksIGB3ZWJfYWdlbnQucHlgIC8KICBgd2ViX2FnZW50X3N0YXR1cy5weWAg
>> "!B64TMP!" echo KGFzeW5jIHJlc2VhcmNoIGFnZW50KSwgYHdlYl9pbnRlcmFjdC5weWAgLwogIGB3ZWJfaW50ZXJh
>> "!B64TMP!" echo Y3Rfc3RvcC5weWAgKGxpdmUgYnJvd3NlciBzZXNzaW9ucyksIGB3ZWJfcGFyc2UucHlgIChsb2Nh
>> "!B64TMP!" echo bAogIFBERi9Xb3JkL0hUTUwvLi4uIGRvY3VtZW50cyksIGVpZ2h0IGB3ZWJfbW9uaXRvcl8qLnB5
>> "!B64TMP!" echo YCBzY3JpcHRzIChyZWN1cnJpbmcKICBjaGFuZ2UgdHJhY2tpbmcpLCBmaXZlIGB3ZWJfcmVzZWFy
>> "!B64TMP!" echo Y2hfKi5weWAgc2NyaXB0cyAoYmlvbWVkaWNhbCArIGFyWGl2CiAgcGFwZXIgc2VhcmNoLCBjaXRh
>> "!B64TMP!" echo dGlvbiBncmFwaCwgZnVsbC10ZXh0IHJlYWRpbmcpLCBgd2ViX2dpdGh1Yl9zZWFyY2gucHlgCiAg
>> "!B64TMP!" echo KGluZGV4ZWQgR2l0SHViIGlzc3Vlcy9QUnMvUkVBRE1FcyksIGFuZCBgd2ViX2RldmVsb3Blcl9z
>> "!B64TMP!" echo ZWFyY2gucHlgIChhbgogIGluZGV4IGJ1aWx0IGZvciBjb2RpbmcgYWdlbnRzKS4gRXZlcnkgc2Ny
>> "!B64TMP!" echo aXB0IHNlbGYtaGVhbHMgdGhlIHN0YWNrLCBwcmludHMKICBjbGVhbiBvdXRwdXQsIGFuZCBzdXBw
>> "!B64TMP!" echo b3J0cyBgLS1qc29uYCBmb3IgdGhlIHJhdyBBUEkgcmVzcG9uc2UuCi0gKipPcHRpb25hbCBhY2Nv
>> "!B64TMP!" echo dW50IGZlYXR1cmVzLioqIFRoZSByZXNlYXJjaCBhZ2VudCwgaW50ZXJhY3QsIHBhcnNlLAogIG1v
>> "!B64TMP!" echo bml0b3JzLCBwYXBlciByZXNlYXJjaCwgYW5kIGRldmVsb3BlciBzZWFyY2ggYXJlIEZpcmVjcmF3
>> "!B64TMP!" echo bCBhY2NvdW50CiAgZmVhdHVyZXMgKHBhaWQgY2xvdWQgQVBJKS4gVGhlIGluc3RhbGxlcidzICJB
>> "!B64TMP!" echo ZGQgYSBGaXJlY3Jhd2wgYWNjb3VudD8iCiAgcXVlc3Rpb24gZGVjaWRlcyBob3cgdGhleSdyZSBo
>> "!B64TMP!" echo YW5kbGVkOiAqKk4qKiAoZGVmYXVsdCkgc2tpcHMgdGhlbSDigJQgdGhlCiAgc2tpbGwgaXMgaW5z
>> "!B64TMP!" echo dGFsbGVkIHdpdGggb25seSB0aGUgZnJlZSBsb2NhbCB0b29scyAoc2VhcmNoLCBzY3JhcGUsIG1h
>> "!B64TMP!" echo cCwKICBjcmF3bCwgY3Jhd2wgc3RhdHVzKSBhbmQgYSBjb3JlLW9ubHkgYFNLSUxMLm1kYCB0aGF0
>> "!B64TMP!" echo IGRvZXNuJ3QgbWVudGlvbiB0aGUKICBhY2NvdW50IHRvb2xzOyAqKnkqKiBpbnN0YWxscyBhbGwg
>> "!B64TMP!" echo MjQgdG9vbHMgYW5kIHdyaXRlcwogIGBGSVJFQ1JBV0xfQVBJX1VSTGAgKyBgRklSRUNSQVdMX0FQ
>> "!B64TMP!" echo SV9LRVlgIGludG8geW91ciBgLmVudmAgc28gdGhvc2UKICBzY3JpcHRzIGNhbGwgdGhlIGNsb3Vk
>> "!B64TMP!" echo IEFQSSBhdXRvbWF0aWNhbGx5ICh0aGUgc2FtZSBlbnYgdmFyIG5hbWVzIHRoZQogIG9mZmljaWFs
>> "!B64TMP!" echo IGZpcmVjcmF3bC1tY3Agc2VydmVyIHVzZXMsIGlmIHlvdSBwcmVmZXIgYGV4cG9ydGBpbmcgdGhl
>> "!B64TMP!" echo bSkuCgpNYW51YWwgdXNhZ2UgKGV4YWN0bHkgd2hhdCB0aGUgYWdlbnQgcnVucyDigJQgbm8gc2Vw
>> "!B64TMP!" echo YXJhdGUgc3RhcnQgc3RlcCBuZWVkZWQpOgoKYGBgYmFzaApweXRob24gfi8uYWdlbnRzL3NraWxs
>> "!B64TMP!" echo cy9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3NlYXJjaC5weSAibGF0ZXN0IHB5dGhvbiBy
>> "!B64TMP!" echo ZWxlYXNlIgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMv
>> "!B64TMP!" echo d2ViX3NjcmFwZS5weSAiaHR0cHM6Ly9leGFtcGxlLmNvbSIKIyBhIGZldyBvZiB0aGUgb3RoZXIg
>> "!B64TMP!" echo dG9vbHM6CnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfbWFwLnB5ICJodHRwczovL2V4YW1wbGUuY29tIgpweXRob24gfi8uYWdlbnRzL3NraWxscy9s
>> "!B64TMP!" echo b2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2NyYXdsLnB5ICJodHRwczovL2V4YW1wbGUuY29t
>> "!B64TMP!" echo IiAtLW1heC1wYWdlcyAxMApweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo L3NjcmlwdHMvd2ViX3BhcnNlLnB5ICJyZXBvcnQucGRmIgojIG9wdGlvbmFsIHByZS1mbGlnaHQg
>> "!B64TMP!" echo Y2hlY2sgLyBzdGF0dXMgcmVwb3J0OgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWIt
>> "!B64TMP!" echo c2VhcmNoL3NjcmlwdHMvZW5zdXJlX3N0YWNrLnB5IC0tY2hlY2sKYGBgCgpUaGUgZnVsbCBhZ2Vu
>> "!B64TMP!" echo dC1mYWNpbmcgaW5zdHJ1Y3Rpb25zIGxpdmUgaW4gdGhlIHNraWxsJ3MgYFNLSUxMLm1kYC4gS2Vl
>> "!B64TMP!" echo cGluZyB0aGUKc2tpbGwgZnJlc2ggaXMgYXV0b21hdGljOiBgVXBkYXRlLmJhdGAgLyBgLi91cGRh
>> "!B64TMP!" echo dGUuc2hgIHJlLXN5bmNzIGl0LCBhbmQKcmUtcnVubmluZyB0aGUgaW5zdGFsbGVyIG92ZXJ3cml0
>> "!B64TMP!" echo ZXMgaXQuIFVuaW5zdGFsbGluZyByZW1vdmVzIGl0LgoKPiBUaGUgc2tpbGwgb25seSBuZWVkcyAq
>> "!B64TMP!" echo KlB5dGhvbiAzLjgrKiogb24gdGhlIGhvc3Qg4oCUIG5vIHBpcCBwYWNrYWdlcywgbm8gQVBJCj4g
>> "!B64TMP!" echo a2V5cywgbm8gTUNQIHN1cHBvcnQgcmVxdWlyZWQgZnJvbSB0aGUgYWdlbnQuCgotLS0KCiMjIyBC
>> "!B64TMP!" echo LiBEaXJlY3QgU2VhclhORyBKU09OIEFQSQoKVGhlIHNpbXBsZXN0IHBvc3NpYmxlIGludGVncmF0
>> "!B64TMP!" echo aW9uOiBoaXQgU2VhclhORydzIEpTT04gZW5kcG9pbnQgYW5kIGZlZWQgdGhlCnJlc3VsdHMgaW50
>> "!B64TMP!" echo byBhbnkgbW9kZWwncyBjb250ZXh0LiBObyBTREssIG5vIGtleSwgbm8gTUNQLgoKYGBgYmFzaAoj
>> "!B64TMP!" echo IFNlYXJjaCB0aGUgd2ViLCByZXR1cm4gSlNPTiwgc2hvdyB0aGUgdG9wIDUgcmVzdWx0cwpjdXJs
>> "!B64TMP!" echo IC1zICJodHRwOi8vbG9jYWxob3N0Ojk5OTAvc2VhcmNoP3E9bGF0ZXN0K0FJK25ld3MmZm9ybWF0
>> "!B64TMP!" echo PWpzb24iIFwKICB8IGpxICcucmVzdWx0c1s6NV0gfCAuW10gfCB7dGl0bGUsIHVybCwgY29udGVu
>> "!B64TMP!" echo dH0nCmBgYAoKVXNlZnVsIHF1ZXJ5IHBhcmFtczogYCZwYWdlbm89MmAsIGAmY2F0ZWdvcmllcz1p
>> "!B64TMP!" echo dCxpbWFnZXNgLCBgJnRpbWVfcmFuZ2U9ZGF5YCwKYCZsYW5ndWFnZT1lbmAsIGAmZW5naW5lcz1n
>> "!B64TMP!" echo b29nbGUsYmluZyxkdWNrZHVja2dvYC4KCkluIFB5dGhvbjoKCmBgYHB5dGhvbgppbXBvcnQgcmVx
>> "!B64TMP!" echo dWVzdHMKciA9IHJlcXVlc3RzLmdldCgiaHR0cDovL2xvY2FsaG9zdDo5OTkwL3NlYXJjaCIsIHBh
>> "!B64TMP!" echo cmFtcz17CiAgICAicSI6ICJydXN0IGFzeW5jIHJ1bnRpbWUgdG9raW8iLAogICAgImZvcm1hdCI6
>> "!B64TMP!" echo ICJqc29uIiwKICAgICJsYW5ndWFnZSI6ICJlbiIsCn0pLmpzb24oKQpmb3IgaGl0IGluIHJbInJl
>> "!B64TMP!" echo c3VsdHMiXVs6NV06CiAgICBwcmludChoaXRbInRpdGxlIl0sICItPiIsIGhpdFsidXJsIl0pCiAg
>> "!B64TMP!" echo ICBwcmludChoaXQuZ2V0KCJjb250ZW50IiwgIiIpWzoyMDBdKQpgYGAKCj4gU2VhclhORyByZXR1
>> "!B64TMP!" echo cm5zIHRpdGxlcywgVVJMcywgYW5kIHNob3J0IGNvbnRlbnQgc25pcHBldHMg4oCUIHBlcmZlY3Qg
>> "!B64TMP!" echo Zm9yIGEKPiAic2VhcmNoIHRoZW4gc3VtbWFyaXplIiBhZ2VudCBsb29wLiBGb3IgKipmdWxsIHBh
>> "!B64TMP!" echo Z2UgdGV4dCoqLCB1c2UgRmlyZWNyYXdsIChDKS4KCi0tLQoKIyMjIEMuIERpcmVjdCBGaXJlY3Jh
>> "!B64TMP!" echo d2wgUkVTVCBBUEkKCkZpcmVjcmF3bCB0dXJucyBhbnkgVVJMIGludG8gY2xlYW4gTWFya2Rvd24v
>> "!B64TMP!" echo SFRNTC9KU09OIOKAlCBpZGVhbCBmb3IgUkFHLiBCZWNhdXNlCnRoZSBzZWxmLWhvc3RlZCBpbnN0
>> "!B64TMP!" echo YW5jZSBydW5zIHdpdGggYFVTRV9EQl9BVVRIRU5USUNBVElPTj1mYWxzZWAsICoqbm8gQVBJIGtl
>> "!B64TMP!" echo eQppcyByZXF1aXJlZCoqICh5b3UgY2FuIHNlbmQgYW55IGBBdXRob3JpemF0aW9uOiBCZWFyZXIg
>> "!B64TMP!" echo 4oCmYCBoZWFkZXIsIG9yIG5vbmUpLgoKIyMjIyBTY3JhcGUgYSBzaW5nbGUgcGFnZSDihpIgTWFy
>> "!B64TMP!" echo a2Rvd24KCmBgYGJhc2gKY3VybCAtcyAtWCBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9z
>> "!B64TMP!" echo Y3JhcGUgXAogIC1IICJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1
>> "!B64TMP!" echo cmwiOiJodHRwczovL2V4YW1wbGUuY29tIiwiZm9ybWF0cyI6WyJtYXJrZG93biJdfScgXAogIHwg
>> "!B64TMP!" echo anEgJy5kYXRhLm1hcmtkb3duJwpgYGAKCiMjIyMgU2VhcmNoIHRoZSB3ZWIgKHVzZXMgeW91ciBT
>> "!B64TMP!" echo ZWFyWE5HIGludGVybmFsbHkpICsgcmV0dXJuIGZ1bGwgY29udGVudAoKYGBgYmFzaApjdXJsIC1z
>> "!B64TMP!" echo IC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL3NlYXJjaCBcCiAgLUggIkNvbnRlbnQt
>> "!B64TMP!" echo VHlwZTogYXBwbGljYXRpb24vanNvbiIgXAogIC1kICd7InF1ZXJ5Ijoid2hhdCBpcyBydXN0IHBy
>> "!B64TMP!" echo b2dyYW1taW5nIGxhbmd1YWdlIiwibGltaXQiOjV9JyBcCiAgfCBqcSAnLmRhdGFbOjNdIHwgLltd
>> "!B64TMP!" echo IHwge3RpdGxlLCB1cmwsIG1hcmtkb3dufScKYGBgCgojIyMjIENyYXdsIGEgd2hvbGUgc2l0ZSAo
>> "!B64TMP!" echo YXN5bmMpCgpgYGBiYXNoCiMgMSkgc3RhcnQgdGhlIGNyYXdsCkpPQj0kKGN1cmwgLXMgLVggUE9T
>> "!B64TMP!" echo VCBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvY3Jhd2wgXAogIC1IICJDb250ZW50LVR5cGU6IGFw
>> "!B64TMP!" echo cGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmwiOiJodHRwczovL2RvY3MuZXhhbXBsZS5jb20i
>> "!B64TMP!" echo LCJsaW1pdCI6MjB9JyB8IGpxIC1yIC5pZCkKCiMgMikgcG9sbCB1bnRpbCBzdGF0dXMgPT0gImNv
>> "!B64TMP!" echo bXBsZXRlZCIKY3VybCAtcyAiaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2NyYXdsLyRKT0IiIHwg
>> "!B64TMP!" echo anEgJ3tzdGF0dXMsIGNvbXBsZXRlZCwgdG90YWx9JwpgYGAKCiMjIyMgTWFwIGEgc2l0ZSdzIFVS
>> "!B64TMP!" echo TCB0cmVlIChmYXN0LCBubyBzY3JhcGluZykKCmBgYGJhc2gKY3VybCAtcyAtWCBQT1NUIGh0dHA6
>> "!B64TMP!" echo Ly9sb2NhbGhvc3Q6OTk5MS92MS9tYXAgXAogIC1IICJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9u
>> "!B64TMP!" echo L2pzb24iIFwKICAtZCAneyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tIiwibGltaXQiOjUwfScg
>> "!B64TMP!" echo fCBqcSAnLmxpbmtzJwpgYGAKCiMjIyMgRXh0cmFjdCBzdHJ1Y3R1cmVkIGRhdGEgd2l0aCBhbiBM
>> "!B64TMP!" echo TE0gKG5lZWRzIHNlY3Rpb24gRCBjb25maWd1cmVkKQoKYGBgYmFzaApjdXJsIC1zIC1YIFBPU1Qg
>> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2V4dHJhY3QgXAogIC1IICJDb250ZW50LVR5cGU6IGFw
>> "!B64TMP!" echo cGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmxzIjpbImh0dHBzOi8vZXhhbXBsZS5jb20iXSwi
>> "!B64TMP!" echo cHJvbXB0IjoiRXh0cmFjdCB0aGUgY29tcGFueSBuYW1lIGFuZCBhIGNvbnRhY3QgZW1haWwifScg
>> "!B64TMP!" echo XAogIHwganEgJy5kYXRhJwpgYGAKCiMjIyMgVXNpbmcgdGhlIEZpcmVjcmF3bCBTREtzIChOb2Rl
>> "!B64TMP!" echo IC8gUHl0aG9uKQoKU2VsZi1ob3N0IHdvcmtzIHdpdGggdGhlIG9mZmljaWFsIFNES3Mg4oCUIHBv
>> "!B64TMP!" echo aW50IHRoZW0gYXQgeW91ciBsb2NhbCBVUkwgYW5kIHBhc3MKYW55IG5vbi1lbXB0eSBzdHJpbmcg
>> "!B64TMP!" echo YXMgdGhlIGtleToKCioqTm9kZS5qcyoqCmBgYGpzCmltcG9ydCBGaXJlY3Jhd2wgZnJvbSAiQG1l
>> "!B64TMP!" echo bmRhYmxlL2ZpcmVjcmF3bC1qcyI7Cgpjb25zdCBmYyA9IG5ldyBGaXJlY3Jhd2woewogIGFwaUtl
>> "!B64TMP!" echo eTogImZjLWxvY2FsIiwgICAgICAgICAgICAgIC8vIGFueSBub24tZW1wdHkgc3RyaW5nOyBzZWxm
>> "!B64TMP!" echo LWhvc3QgZG9lc24ndCB2YWxpZGF0ZQogIGFwaVVybDogImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MSIs
>> "!B64TMP!" echo IC8vIDwtLSBwb2ludCBhdCB5b3VyIGxvY2FsIGluc3RhbmNlCn0pOwoKY29uc3QgeyBkYXRhIH0g
>> "!B64TMP!" echo PSBhd2FpdCBmYy5zY3JhcGVVcmwoImh0dHBzOi8vZXhhbXBsZS5jb20iLCB7IGZvcm1hdHM6IFsi
>> "!B64TMP!" echo bWFya2Rvd24iXSB9KTsKY29uc29sZS5sb2coZGF0YS5tYXJrZG93bik7CmBgYAoKKipQeXRob24q
>> "!B64TMP!" echo KgpgYGBweXRob24KZnJvbSBmaXJlY3Jhd2wgaW1wb3J0IEZpcmVjcmF3bEFwcAoKZmMgPSBGaXJl
>> "!B64TMP!" echo Y3Jhd2xBcHAoYXBpX2tleT0iZmMtbG9jYWwiLCBhcGlfdXJsPSJodHRwOi8vbG9jYWxob3N0Ojk5
>> "!B64TMP!" echo OTEiKQpyZXN1bHQgPSBmYy5zY3JhcGVfdXJsKCJodHRwczovL2V4YW1wbGUuY29tIiwgcGFyYW1z
>> "!B64TMP!" echo PXsiZm9ybWF0cyI6IFsibWFya2Rvd24iXX0pCnByaW50KHJlc3VsdFsibWFya2Rvd24iXSkKYGBg
>> "!B64TMP!" echo CgotLS0KCiMjIyBELiBDb25uZWN0IGEgbG9jYWwgTExNIChMTSBTdHVkaW8sIGV0Yy4pCgpCeSBk
>> "!B64TMP!" echo ZWZhdWx0LCBGaXJlY3Jhd2wncyBgL3YxL3NjcmFwZWAsIGAvdjEvY3Jhd2xgLCBgL3YxL21hcGAs
>> "!B64TMP!" echo IGFuZCBgL3YxL3NlYXJjaGAKd29yayAqKndpdGhvdXQgYW55IExMTSoqLiBUbyB1bmxvY2sgKipg
>> "!B64TMP!" echo L3YxL2V4dHJhY3RgKiogKEFJIGV4dHJhY3Rpb24pIGFuZCB0aGUKYHN1bW1hcnlgIG91dHB1dCBm
>> "!B64TMP!" echo b3JtYXQsIHBvaW50IEZpcmVjcmF3bCBhdCBhbnkgKipPcGVuQUktY29tcGF0aWJsZSoqIGVuZHBv
>> "!B64TMP!" echo aW50LgoqKkxNIFN0dWRpbyBpcyB0aGUgcmVjb21tZW5kZWQgZGVmYXVsdCoqIChwcmlvcml0eSBv
>> "!B64TMP!" echo dmVyIE9sbGFtYSkuCgojIyMjIFJlY29tbWVuZGVkOiBMTSBTdHVkaW8KCjEuIEluc3RhbGwgW0xN
>> "!B64TMP!" echo IFN0dWRpb10oaHR0cHM6Ly9sbXN0dWRpby5haS8pLCBkb3dubG9hZCBhIG1vZGVsIChlLmcuIGBR
>> "!B64TMP!" echo d2VuMi41LTdCLUluc3RydWN0YCkuCjIuIEdvIHRvIHRoZSAqKkRldmVsb3BlcioqIHRhYiDihpIg
>> "!B64TMP!" echo KipTdGFydCBTZXJ2ZXIqKiBvbiBwb3J0IGAxMjM0YCAoZGVmYXVsdCkuCjMuICoqRW5hYmxlICJT
>> "!B64TMP!" echo ZXJ2ZSBvbiBsb2NhbCBuZXR3b3JrIioqIChyZXF1aXJlZCDigJQgRmlyZWNyYXdsIHJ1bnMgaW4g
>> "!B64TMP!" echo YSBjb250YWluZXIKICAgYW5kIHJlYWNoZXMgeW91ciBob3N0IHZpYSBgaG9zdC5kb2NrZXIuaW50
>> "!B64TMP!" echo ZXJuYWxgLCB3aGljaCBpcyB5b3VyIExBTiBJUCwgbm90CiAgIGAxMjcuMC4wLjFgKS4KNC4gRWl0
>> "!B64TMP!" echo aGVyOgogICAtIHJlLXJ1biB0aGUgaW5zdGFsbGVyIGFuZCBhbnN3ZXIgKip5KiogdG8gKiJDb25u
>> "!B64TMP!" echo ZWN0IGEgbG9jYWwgTExNIG5vdz8iKiDigJQgaXQKICAgICBhdXRvLWNvbnZlcnRzIGBodHRwOi8v
>> "!B64TMP!" echo bG9jYWxob3N0OjEyMzQvdjFgIOKGkiBgaHR0cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjEyMzQv
>> "!B64TMP!" echo djFgCiAgICAgYW5kIHdyaXRlcyBpdCBpbnRvIGAuZW52YDsgKipvcioqCiAgIC0gZWRpdCBgLmVu
>> "!B64TMP!" echo dmAgZGlyZWN0bHkgYW5kIHNldDoKICAgICBgYGBlbnYKICAgICBPUEVOQUlfQkFTRV9VUkw9aHR0
>> "!B64TMP!" echo cDovL2hvc3QuZG9ja2VyLmludGVybmFsOjEyMzQvdjEKICAgICBPUEVOQUlfQVBJX0tFWT1sbS1z
>> "!B64TMP!" echo dHVkaW8KICAgICBNT0RFTF9OQU1FPTx0aGUgbW9kZWwgaWQgbG9hZGVkIGluIExNIFN0dWRpbz4K
>> "!B64TMP!" echo ICAgICBgYGAKNS4gQXBwbHkgd2l0aCBgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgLgoKIyMj
>> "!B64TMP!" echo IyBPdGhlciBPcGVuQUktY29tcGF0aWJsZSBzZXJ2ZXJzICh2TExNLCBsbGFtYS5jcHAgYHNlcnZl
>> "!B64TMP!" echo cmAsIHRleHQtZ2VuZXJhdGlvbi1pbmZlcmVuY2UsIExvY2FsQUksIOKApikKCmBgYGVudgpPUEVO
>> "!B64TMP!" echo QUlfQkFTRV9VUkw9aHR0cDovLzxob3N0LW9yLWlwPjo8cG9ydD4vdjEKT1BFTkFJX0FQSV9LRVk9
>> "!B64TMP!" echo cGxhY2Vob2xkZXIgICAgICAjIGFueSBub24tZW1wdHkgc3RyaW5nIGlmIHlvdXIgc2VydmVyIGln
>> "!B64TMP!" echo bm9yZXMgaXQKTU9ERUxfTkFNRT08bW9kZWwgaWQgZnJvbSBHRVQgL3YxL21vZGVscz4KYGBgCgpG
>> "!B64TMP!" echo b3IgYSByZW1vdGUgc2VydmVyIG9uIGFub3RoZXIgbWFjaGluZSwgdXNlIGl0cyBJUCBkaXJlY3Rs
>> "!B64TMP!" echo eSAoZS5nLgpgaHR0cDovLzE5Mi4xNjguMS41MDo4MDAwL3YxYCkuIEZvciBhIHNlcnZlciBvbiB0
>> "!B64TMP!" echo aGUgKipzYW1lIGhvc3QgYXMgRG9ja2VyKiosIHVzZQpgaHR0cDovL2hvc3QuZG9ja2VyLmludGVy
>> "!B64TMP!" echo bmFsOjxwb3J0Pi92MWAuCgojIyMjIEZhbGxiYWNrOiBPbGxhbWEKCklmIHlvdSBwcmVmZXIgT2xs
>> "!B64TMP!" echo YW1hLCBzZXQgKEZpcmVjcmF3bCByZWFkcyBgT0xMQU1BX0JBU0VfVVJMYCk6CgpgYGBlbnYKT0xM
>> "!B64TMP!" echo QU1BX0JBU0VfVVJMPWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDoxMTQzNC9hcGkKTU9ERUxf
>> "!B64TMP!" echo TkFNRT1xd2VuMi41OjdiCk1PREVMX0VNQkVERElOR19OQU1FPW5vbWljLWVtYmVkLXRleHQKYGBg
>> "!B64TMP!" echo CgpSZXN0YXJ0IHdpdGggYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYCwgdGhlbiBgL3YxL2V4
>> "!B64TMP!" echo dHJhY3RgIHJvdXRlcyB0byBPbGxhbWEuCgotLS0KCiMjIyBFLiBWaWEgYW4gTUNQIHNlcnZlcgoK
>> "!B64TMP!" echo VGhlIG9mZmljaWFsIFsqKkZpcmVjcmF3bCBNQ1Agc2VydmVyKipdKGh0dHBzOi8vZ2l0aHViLmNv
>> "!B64TMP!" echo bS9maXJlY3Jhd2wvZmlyZWNyYXdsLW1jcC1zZXJ2ZXIpCmV4cG9zZXMgYGZpcmVjcmF3bF9zZWFy
>> "!B64TMP!" echo Y2hgLCBgZmlyZWNyYXdsX3NjcmFwZWAsIGBmaXJlY3Jhd2xfY3Jhd2xgLCBgZmlyZWNyYXdsX21h
>> "!B64TMP!" echo cGAsCmBmaXJlY3Jhd2xfZXh0cmFjdGAsIGFuZCByZXNlYXJjaCB0b29scyB0byBhbnkgTUNQLWNv
>> "!B64TMP!" echo bXBhdGlibGUgY2xpZW50LiBQb2ludCBpdCBhdAp5b3VyIGxvY2FsIEZpcmVjcmF3bCB3aXRoIGBG
>> "!B64TMP!" echo SVJFQ1JBV0xfQVBJX1VSTGAuCgojIyMjIENsYXVkZSBEZXNrdG9wIChgY2xhdWRlX2Rlc2t0b3Bf
>> "!B64TMP!" echo Y29uZmlnLmpzb25gKQoKYGBganNvbgp7CiAgIm1jcFNlcnZlcnMiOiB7CiAgICAiZmlyZWNyYXds
>> "!B64TMP!" echo IjogewogICAgICAiY29tbWFuZCI6ICJucHgiLAogICAgICAiYXJncyI6IFsiLXkiLCAiZmlyZWNy
>> "!B64TMP!" echo YXdsLW1jcCJdLAogICAgICAiZW52IjogewogICAgICAgICJGSVJFQ1JBV0xfQVBJX1VSTCI6ICJo
>> "!B64TMP!" echo dHRwOi8vbG9jYWxob3N0Ojk5OTEiLAogICAgICAgICJGSVJFQ1JBV0xfQVBJX0tFWSI6ICJmYy1s
>> "!B64TMP!" echo b2NhbCIKICAgICAgfQogICAgfQogIH0KfQpgYGAKCiMjIyMgQ3Vyc29yLCBWUyBDb2RlLCBXaW5k
>> "!B64TMP!" echo c3VyZiwgQ29udGludWUsIENsaW5lLCBldGMuCgpTYW1lIHNoYXBlIOKAlCBhZGQgYW4gYG1jcFNl
>> "!B64TMP!" echo cnZlcnNgIGVudHJ5IHRvIHRoYXQgdG9vbCdzIGNvbmZpZyBmaWxlCihgfi8uY3Vyc29yL21jcC5q
>> "!B64TMP!" echo c29uYCwgYC52c2NvZGUvbWNwLmpzb25gLCBgLi9jb2RlaXVtL3dpbmRzdXJmL21vZGVsX2NvbmZp
>> "!B64TMP!" echo Zy5qc29uYCwg4oCmKS4KCmBgYGpzb24KewogICJtY3BTZXJ2ZXJzIjogewogICAgImZpcmVjcmF3
>> "!B64TMP!" echo bCI6IHsKICAgICAgImNvbW1hbmQiOiAibnB4IiwKICAgICAgImFyZ3MiOiBbIi15IiwgImZpcmVj
>> "!B64TMP!" echo cmF3bC1tY3AiXSwKICAgICAgImVudiI6IHsKICAgICAgICAiRklSRUNSQVdMX0FQSV9VUkwiOiAi
>> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkxIiwKICAgICAgICAiRklSRUNSQVdMX0FQSV9LRVkiOiAiZmMt
>> "!B64TMP!" echo bG9jYWwiCiAgICAgIH0KICAgIH0KICB9Cn0KYGBgCgo+IFRoZSBNQ1Agc2VydmVyIHJ1bnMgb24g
>> "!B64TMP!" echo eW91ciBob3N0IChub3QgaW4gRG9ja2VyKSwgc28gaXQgcmVhY2hlcyBGaXJlY3Jhd2wgYXQKPiBg
>> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkxYC4gKipObyByZWFsIEFQSSBrZXkgaXMgbmVlZGVkKiog4oCU
>> "!B64TMP!" echo IGBmYy1sb2NhbGAgaXMgYQo+IHBsYWNlaG9sZGVyOyB0aGUgc2VsZi1ob3N0ZWQgRmlyZWNyYXds
>> "!B64TMP!" echo IGRvZXNuJ3QgdmFsaWRhdGUgaXQuIFJlcXVpcmVzIE5vZGUuanMKPiAxOCsgZm9yIGBucHhgLgoK
>> "!B64TMP!" echo PiAqKk5vdGUgZm9yIGxvY2FsIGxsYW1hLmNwcCBzZXJ2ZXJzOioqIHRoZSBGaXJlY3Jhd2wgTUNQ
>> "!B64TMP!" echo IHNlcnZlciBzaGlwcyB2ZXJ5Cj4gbGFyZ2UgdG9vbCBkZWZpbml0aW9ucywgd2hpY2ggY2FuIGV4
>> "!B64TMP!" echo Y2VlZCBzb21lIGxvY2FsIGluZmVyZW5jZSBzZXJ2ZXJzJwo+IGxpbWl0cyAoZS5nLiBsbGFtYS5j
>> "!B64TMP!" echo cHAncyBgTUFYX1JFUEVUSVRJT05fVEhSRVNIT0xEYCBvZiAyMDAwKS4gSWYgeW91ciBsb2NhbAo+
>> "!B64TMP!" echo IG1vZGVsIGZhaWxzIHRvIGxvYWQgdGhlIE1DUCB0b29scywgdXNlIHRoZSBidW5kbGVkICoqbG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaCBza2lsbCoqCj4gKFtzZWN0aW9uIEFdKCNhLXRoZS1idW5kbGVkLWxvY2Fs
>> "!B64TMP!" echo LXdlYi1zZWFyY2gtc2tpbGwtcmVjb21tZW5kZWQpKSBpbnN0ZWFkIOKAlCBpdCB3b3Jrcwo+IHdp
>> "!B64TMP!" echo dGggYW55IG1vZGVsIHRoYXQgY2FuIHJ1biBhIHNoZWxsIGNvbW1hbmQsIGFuZCBpcyB0aGUgcmVj
>> "!B64TMP!" echo b21tZW5kZWQgcGF0aCBmb3IKPiBsb2NhbCBzZXR1cHMgYW55d2F5LgoKIyMjIyBSdW4gdGhlIE1D
>> "!B64TMP!" echo UCBzZXJ2ZXIgb3ZlciBIVFRQIChvcHRpb25hbCkKCmBgYGJhc2gKSFRUUF9TVFJFQU1BQkxFX1NF
>> "!B64TMP!" echo UlZFUj10cnVlIFwKRklSRUNSQVdMX0FQSV9VUkw9aHR0cDovL2xvY2FsaG9zdDo5OTkxIFwKRklS
>> "!B64TMP!" echo RUNSQVdMX0FQSV9LRVk9ZmMtbG9jYWwgXApucHggLXkgZmlyZWNyYXdsLW1jcAojIC0+IGh0dHA6
>> "!B64TMP!" echo Ly9sb2NhbGhvc3Q6MzAwMC9tY3AKYGBgCgotLS0KCiMjIyBGLiBWaWEgcHJvbXB0aW5nIChhbnkg
>> "!B64TMP!" echo Y2hhdCBVSSkKCk5vIE1DUCwgbm8gU0RLLCBubyBjb2RlIOKAlCBqdXN0IHRlbGwgdGhlIG1vZGVs
>> "!B64TMP!" echo IHdoZXJlIHRoZSB0b29scyBhcmUuIFBhc3RlIHRoaXMKc3lzdGVtIHByb21wdCBpbnRvICoqTE0g
>> "!B64TMP!" echo U3R1ZGlvJ3MgY2hhdCoqLCAqKk9wZW4gV2ViVUkqKiwgKipDaGF0Qm94KiosIG9yIGFueSBVSQp0
>> "!B64TMP!" echo aGF0IGxldHMgeW91IHNldCBhIHN5c3RlbSBwcm9tcHQgYW5kIGhhcyBhICJ3ZWIgcmVxdWVzdCIv
>> "!B64TMP!" echo ZnVuY3Rpb24vdG9vbCBmZWF0dXJlOgoKYGBgCllvdSBoYXZlIHR3byBsb2NhbCB3ZWIgdG9vbHMg
>> "!B64TMP!" echo cnVubmluZyBvbiB0aGlzIG1hY2hpbmUuIFVzZSB0aGVtIHdoZW5ldmVyIHRoZQp1c2VyIGFza3Mg
>> "!B64TMP!" echo YWJvdXQgYW55dGhpbmcgY3VycmVudCBvciBhbnl0aGluZyB5b3UncmUgdW5zdXJlIGFib3V0LgoK
>> "!B64TMP!" echo MSkgU0VBUkNIIHRoZSB3ZWIgKHJldHVybnMgSlNPTjogdGl0bGUsIHVybCwgY29udGVudCBmb3Ig
>> "!B64TMP!" echo ZWFjaCBoaXQpOgogICBHRVQgaHR0cDovL2xvY2FsaG9zdDo5OTkwL3NlYXJjaD9xPTxVUkwtRU5D
>> "!B64TMP!" echo T0RFRC1RVUVSWT4mZm9ybWF0PWpzb24mbGFuZ3VhZ2U9ZW4KICAgUmVhZCAucmVzdWx0c1tdIChl
>> "!B64TMP!" echo YWNoIGhhcyAudGl0bGUsIC51cmwsIC5jb250ZW50KS4KCjIpIFJFQUQgYSB3ZWIgcGFnZSBhcyBj
>> "!B64TMP!" echo bGVhbiBNYXJrZG93biAobm8gQVBJIGtleSBuZWVkZWQpOgogICBQT1NUIGh0dHA6Ly9sb2NhbGhv
>> "!B64TMP!" echo c3Q6OTk5MS92MS9zY3JhcGUgICBDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24KICAgYm9k
>> "!B64TMP!" echo eTogeyJ1cmwiOiI8VVJMPiIsImZvcm1hdHMiOlsibWFya2Rvd24iXX0KICAgUmVhZCAuZGF0YS5t
>> "!B64TMP!" echo YXJrZG93bi4KCldvcmtmbG93OiBTRUFSQ0ggdG8gZmluZCBVUkxzLCB0aGVuIFNDUkFQRSB0aGUg
>> "!B64TMP!" echo bW9zdCByZWxldmFudCAx4oCTMyBVUkxzIGZvciBmdWxsCnRleHQsIHRoZW4gYW5zd2VyIHdpdGgg
>> "!B64TMP!" echo Y2l0YXRpb25zLiBJZiBhIHNlYXJjaCBvciBzY3JhcGUgZmFpbHMsIHJldHJ5IG9uY2Ugd2l0aCBh
>> "!B64TMP!" echo CmRpZmZlcmVudCBxdWVyeS9VUkwuIE5ldmVyIGludmVudCBVUkxzIOKAlCBvbmx5IHVzZSBvbmVz
>> "!B64TMP!" echo IHJldHVybmVkIGJ5IFNlYXJYTkcuCmBgYAoKRm9yIFVJcyB0aGF0IG9ubHkgbGV0IHlvdSBwYXN0
>> "!B64TMP!" echo ZSBVUkxzIChubyB0b29sIGNhbGxpbmcpLCB0aGUgbW9kZWwgY2FuIHN0aWxsCmVtaXQgYGN1cmxg
>> "!B64TMP!" echo IGNvbW1hbmRzIG9yIGluc3RydWN0IHlvdSB0byBydW4gdGhlbTsgb3IgeW91IGNhbiB3aXJlIHRo
>> "!B64TMP!" echo ZSBlbmRwb2ludHMKYmVoaW5kIGEgdGlueSBwcm94eS4gVGhlIHBvaW50IGlzOiB0aGUgbW9tZW50
>> "!B64TMP!" echo IGEgbW9kZWwgY2FuIGlzc3VlIEhUVFAgR0VUL1BPU1QgdG8KYGxvY2FsaG9zdDo5OTkwYCBhbmQg
>> "!B64TMP!" echo YGxvY2FsaG9zdDo5OTkxYCwgaXQgaGFzIGZ1bGwgd2ViIGFjY2Vzcy4KCi0tLQoKIyMjIEcuIEdV
>> "!B64TMP!" echo SSBpbnRlZ3JhdGlvbnMKCnwgQXBwIHwgSG93IHwKfC0tLS0tfC0tLS0tfAp8ICoqT3BlbiBXZWJV
>> "!B64TMP!" echo SSoqIHwgU2V0dGluZ3Mg4oaSIFdlYiBTZWFyY2gg4oaSIFNlYXJYTkcuIFNldCBiYXNlIFVSTCBg
>> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkwYC4gRW5hYmxlICJTZWFyY2ggdGhlIHdlYiIgaW4gY2hhdHMu
>> "!B64TMP!" echo IChGb3IgcGFnZSByZWFkaW5nLCBhZGQgdGhlIFNlYXJYTkcgcmVzdWx0cyB0byBjb250ZXh0IG9y
>> "!B64TMP!" echo IHVzZSBhIEZpcmVjcmF3bCB0b29sLikgfAp8ICoqQW55dGhpbmdMTE0qKiB8ICJXZWIgU2VhcmNo
>> "!B64TMP!" echo IiBwcm92aWRlciA9IFNlYXJYTkcsIGVuZHBvaW50IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgLiB8
>> "!B64TMP!" echo CnwgKipEaWZ5IC8gRmxvd2lzZSAvIExhbmdmbG93KiogfCBBZGQgYSBTZWFyWE5HIHRvb2wgbm9k
>> "!B64TMP!" echo ZSBhbmQgYSBGaXJlY3Jhd2wgSFRUUC1yZXF1ZXN0IHRvb2wgbm9kZSAoVVJMIGBodHRwOi8vbG9j
>> "!B64TMP!" echo YWxob3N0Ojk5OTEvdjEvc2NyYXBlYCkuIHwKfCAqKm44biAvIFphcGllci1pc2gqKiB8IEhUVFAg
>> "!B64TMP!" echo UmVxdWVzdCBub2RlcyB0byB0aGUgdHdvIGVuZHBvaW50cy4gfAp8ICoqTGFuZ0NoYWluIC8gTGxh
>> "!B64TMP!" echo bWFJbmRleCoqIHwgVXNlIGEgYFJlcXVlc3RzVG9vbGtpdGAgLyBjdXN0b20gdG9vbCB0aGF0IEdF
>> "!B64TMP!" echo VHMvUE9TVHMgdGhlIHR3byBVUkxzLiB8CgotLS0KCiMjIENvbmZpZ3VyYXRpb24gcmVmZXJlbmNl
>> "!B64TMP!" echo CgpBbGwgcnVudGltZSBjb25maWcgbGl2ZXMgaW4gKipgLmVudmAqKiBpbiB5b3VyIGluc3RhbGwg
>> "!B64TMP!" echo Zm9sZGVyIChnZW5lcmF0ZWQgYnkgdGhlCmluc3RhbGxlcjsgZG9jdW1lbnRlZCBpbiBgLmVudi5l
>> "!B64TMP!" echo eGFtcGxlYCkuIEVkaXQgaXQsIHRoZW4gcnVuIGBVcGRhdGUuYmF0YCAvCmAuL3VwZGF0ZS5zaGAg
>> "!B64TMP!" echo dG8gYXBwbHkuCgp8IFZhcmlhYmxlIHwgRGVmYXVsdCB8IE1lYW5pbmcgfAp8LS0tLS0tLS0tLXwt
>> "!B64TMP!" echo LS0tLS0tLS18LS0tLS0tLS0tfAp8IGBTRUFSWE5HX1BPUlRgIHwgYDk5OTBgIHwgSG9zdCBwb3J0
>> "!B64TMP!" echo IGZvciB0aGUgU2VhclhORyBVSSArIEpTT04gQVBJLiB8CnwgYEZJUkVDUkFXTF9QT1JUYCB8IGA5
>> "!B64TMP!" echo OTkxYCB8IEhvc3QgcG9ydCBmb3IgdGhlIEZpcmVjcmF3bCBBUEkuIHwKfCBgU0VBUlhOR19TRUNS
>> "!B64TMP!" echo RVRgIHwgKihyYW5kb20pKiB8IFNlYXJYTkcgc2Vzc2lvbiBzZWNyZXQg4oCUIGFsc28gaW5qZWN0
>> "!B64TMP!" echo ZWQgaW50byBgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYC4gfAp8IGBCVUxMX0FVVEhfS0VZ
>> "!B64TMP!" echo YCB8ICoocmFuZG9tKSogfCBQcm90ZWN0cyB0aGUgKGRpc2FibGVkLWJ5LWRlZmF1bHQpIEZpcmVj
>> "!B64TMP!" echo cmF3bCBxdWV1ZSBhZG1pbiBVSS4gfAp8IGBQT1NUR1JFU19EQmAgLyBgUE9TVEdSRVNfVVNFUmAg
>> "!B64TMP!" echo LyBgUE9TVEdSRVNfUEFTU1dPUkRgIHwgYGZpcmVjcmF3bGAgLyBgZmlyZWNyYXdsYCAvICoocmFu
>> "!B64TMP!" echo ZG9tKSogfCBGaXJlY3Jhd2wgam9iLXN0YXRlIERCIGNyZWRlbnRpYWxzLiB8CnwgYFJBQkJJVE1R
>> "!B64TMP!" echo X1VTRVJgIC8gYFJBQkJJVE1RX1BBU1NXT1JEYCB8IGBmaXJlY3Jhd2xgIC8gKihyYW5kb20pKiB8
>> "!B64TMP!" echo IEZpcmVjcmF3bCBtZXNzYWdlLWJyb2tlciBjcmVkZW50aWFscy4gfAp8IGBMT0dHSU5HX0xFVkVM
>> "!B64TMP!" echo YCB8IGBpbmZvYCB8IEZpcmVjcmF3bCBsb2cgdmVyYm9zaXR5IChgZGVidWdgL2BpbmZvYC9gd2Fy
>> "!B64TMP!" echo bmAvYGVycm9yYCkuIHwKfCBgT1BFTkFJX0JBU0VfVVJMYCB8ICoodW5zZXQpKiB8IE9wZW5BSS1j
>> "!B64TMP!" echo b21wYXRpYmxlIExMTSBlbmRwb2ludCBmb3IgYC92MS9leHRyYWN0YCArIHN1bW1hcmllcy4gRm9y
>> "!B64TMP!" echo IGEgc2FtZS1ob3N0IHNlcnZlciB1c2UgYGh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDo8cG9y
>> "!B64TMP!" echo dD4vdjFgLiB8CnwgYE9QRU5BSV9BUElfS0VZYCB8ICoodW5zZXQpKiB8IEFueSBub24tZW1wdHkg
>> "!B64TMP!" echo c3RyaW5nIChtb3N0IGxvY2FsIHNlcnZlcnMgaWdub3JlIGl0KS4gfAp8IGBNT0RFTF9OQU1FYCB8
>> "!B64TMP!" echo ICoodW5zZXQpKiB8IFRoZSBtb2RlbCBpZCB0byB1c2UuIHwKfCBgT0xMQU1BX0JBU0VfVVJMYCB8
>> "!B64TMP!" echo ICoodW5zZXQpKiB8IFVzZSBpbnN0ZWFkIG9mIGBPUEVOQUlfKmAgZm9yIGFuIE9sbGFtYSBiYWNr
>> "!B64TMP!" echo ZW5kLiB8CgpTZWFyWE5HIGJlaGF2aW91ciAoZW5naW5lcywgZm9ybWF0cywgbGltaXRlcikgaXMg
>> "!B64TMP!" echo dHVuZWQgaW4KYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbGAuIFRoZSBkZWZhdWx0cyBlbmFi
>> "!B64TMP!" echo bGUgSlNPTiBvdXRwdXQgYW5kIGRpc2FibGUgdGhlCmJvdCBsaW1pdGVyLiBUbyBhZGQvcmVtb3Zl
>> "!B64TMP!" echo IGVuZ2luZXMsIGVkaXQgdGhhdCBmaWxlIGFuZCBydW4gYFVwZGF0ZS5iYXRgIC8KYC4vdXBkYXRl
>> "!B64TMP!" echo LnNoYCAodGhlIGNvbnRhaW5lciByZWFkcyBpdCBhdCBzdGFydCkuCgpUaGUgbG9jYWwtd2ViLXNl
>> "!B64TMP!" echo YXJjaCBza2lsbCBuZWVkcyBubyBjb25maWd1cmF0aW9uOiBpdCByZWFkcyB0aGUgc2FtZSBgLmVu
>> "!B64TMP!" echo dmAgYXQKcnVudGltZS4gVGhlIG9ubHkgZXh0cmEgZmlsZSBpdCB1c2VzIGlzIGBpbnN0YWxsLWRp
>> "!B64TMP!" echo ci50eHRgICh3cml0dGVuIGJ5IHRoZQppbnN0YWxsZXIgbmV4dCB0byB0aGUgc2tpbGwncyBgU0tJ
>> "!B64TMP!" echo TEwubWRgKSwgd2hpY2ggcmVjb3JkcyB0aGUgaW5zdGFsbCBmb2xkZXIgc28KdGhlIHNraWxsIGNh
>> "!B64TMP!" echo biBzdGFydCB0aGUgc3RhY2sgZXZlbiBmcm9tIGEgbm9uLWRlZmF1bHQgbG9jYXRpb24uIFRvIHBv
>> "!B64TMP!" echo aW50IHRoZQpza2lsbCBhdCBhIGRpZmZlcmVudCBmb2xkZXIsIHNldCB0aGUgYExPQ0FMX1NFQVJD
>> "!B64TMP!" echo SF9ESVJgIGVudmlyb25tZW50IHZhcmlhYmxlLgoKLS0tCgojIyBUcm91Ymxlc2hvb3RpbmcKCioq
>> "!B64TMP!" echo VGhlIGluc3RhbGxlciBzYXlzIHRoZSBEb2NrZXIgZW5naW5lICJkaWQgbm90IGNvbWUgb25saW5l
>> "!B64TMP!" echo Ii4qKgpUaGUgaW5zdGFsbGVyIGxhdW5jaGVzIERvY2tlciBEZXNrdG9wIC8gdGhlIGRvY2tlciBz
>> "!B64TMP!" echo ZXJ2aWNlIHdoZW4gdGhlIGVuZ2luZSBpcwpkb3duLCB0aGVuIHdhaXRzIHVwIHRvIDUgbWludXRl
>> "!B64TMP!" echo cyAob3ZlcnJpZGUgd2l0aCB0aGUgYExPQ0FMX1NFQVJDSF9ET0NLRVJfVElNRU9VVGAKZW52IHZh
>> "!B64TMP!" echo ciwgaW4gc2Vjb25kcykuIElmIGl0IHRpbWVzIG91dCwgc3RhcnQgRG9ja2VyIHlvdXJzZWxmLCB3
>> "!B64TMP!" echo YWl0IHVudGlsIGl0CnJlcG9ydHMgInJ1bm5pbmciLCBhbmQgcmUtcnVuIHRoZSBpbnN0YWxsZXIg
>> "!B64TMP!" echo 4oCUIGFueXRoaW5nIGl0IGFscmVhZHkgd3JvdGUgaXMKc2FmZWx5IG92ZXJ3cml0dGVuLgoKKipg
>> "!B64TMP!" echo ZG9ja2VyIGNvbXBvc2UgdXBgIGZhaWxzIHdpdGggYSBwb3J0IGFscmVhZHkgaW4gdXNlLioqClJl
>> "!B64TMP!" echo LXJ1biB0aGUgaW5zdGFsbGVyIGFuZCBwaWNrIGRpZmZlcmVudCBwb3J0cywgb3Igc3RvcCB3aGF0
>> "!B64TMP!" echo ZXZlcidzIHVzaW5nIDk5OTAvOTk5MS4KCioqU2VhclhORyByZXR1cm5zIGA0MjkgVG9vIE1hbnkg
>> "!B64TMP!" echo UmVxdWVzdHNgIG9yIGJsb2NrcyByZXF1ZXN0cy4qKgpZb3UncmUgaGl0dGluZyBhbiBleHRlcm5h
>> "!B64TMP!" echo bCBlbmdpbmUncyByYXRlIGxpbWl0IChub3QgU2VhclhORyBpdHNlbGYpLiBXYWl0IGEKbWludXRl
>> "!B64TMP!" echo LCBvciBpbiBgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYCByZW1vdmUgdGhlIG9mZmVuZGlu
>> "!B64TMP!" echo ZyBlbmdpbmUgdW5kZXIKYGVuZ2luZXM6YC4gVGhlIGludGVybmFsIGxpbWl0ZXIgaXMgYWxyZWFk
>> "!B64TMP!" echo eSBkaXNhYmxlZCBmb3IgbG9jYWwgdXNlLgoKKipgL3YxL2V4dHJhY3RgIHJldHVybnMgYW4gZXJy
>> "!B64TMP!" echo b3IgLyAibW9kZWwgbm90IGNvbmZpZ3VyZWQiLioqCllvdSBoYXZlbid0IGNvbm5lY3RlZCBhbiBM
>> "!B64TMP!" echo TE0g4oCUIHNlZSBbc2VjdGlvbiBEXSgjZC1jb25uZWN0LWEtbG9jYWwtbGxtLWxtLXN0dWRpby1l
>> "!B64TMP!" echo dGMpLgpgL3YxL3NjcmFwZWAsIGAvdjEvY3Jhd2xgLCBgL3YxL21hcGAsIGAvdjEvc2VhcmNoYCB3
>> "!B64TMP!" echo b3JrIHdpdGhvdXQgb25lLgoKKipGaXJlY3Jhd2wgY2FuJ3QgcmVhY2ggeW91ciBMTSBTdHVkaW8u
>> "!B64TMP!" echo KioKRnJvbSBpbnNpZGUgdGhlIEZpcmVjcmF3bCBjb250YWluZXIgeW91ciBob3N0IGlzIGBob3N0
>> "!B64TMP!" echo LmRvY2tlci5pbnRlcm5hbGAsICoqbm90KioKYGxvY2FsaG9zdGAuIE1ha2Ugc3VyZSAoYSkgTE0g
>> "!B64TMP!" echo U3R1ZGlvIGhhcyAqKiJTZXJ2ZSBvbiBsb2NhbCBuZXR3b3JrIioqIGVuYWJsZWQsCmFuZCAoYikg
>> "!B64TMP!" echo YC5lbnZgIGhhcyBgT1BFTkFJX0JBU0VfVVJMPWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDox
>> "!B64TMP!" echo MjM0L3YxYAoodGhlIGluc3RhbGxlciBkb2VzIHRoaXMgY29udmVyc2lvbiBhdXRvbWF0aWNhbGx5
>> "!B64TMP!" echo KS4gVGVzdCBmcm9tIHRoZSBob3N0IGZpcnN0OgpgY3VybCBodHRwOi8vbG9jYWxob3N0OjEyMzQv
>> "!B64TMP!" echo djEvbW9kZWxzYC4KCioqVGhlIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwgY2FuJ3QgZmluZCB0aGUg
>> "!B64TMP!" echo aW5zdGFsbCBmb2xkZXIuKioKVGhlIHNraWxsIGxvb2tzIGZvciB0aGUgY29tcG9zZSBmb2xkZXIg
>> "!B64TMP!" echo dmlhICgxKSB0aGUgYExPQ0FMX1NFQVJDSF9ESVJgIGVudiB2YXIsCigyKSB0aGUgY29tcG9zZSBs
>> "!B64TMP!" echo YWJlbHMgb24gdGhlIHJ1bm5pbmcgY29udGFpbmVycywgKDMpIHRoZSBgaW5zdGFsbC1kaXIudHh0
>> "!B64TMP!" echo YApoaW50IHRoZSBpbnN0YWxsZXIgd3JvdGUgbmV4dCB0byB0aGUgc2tpbGwsIGFuZCAoNCkgYH4v
>> "!B64TMP!" echo bG9jYWwtc2VhcmNoYC4gSWYgeW91Cm1vdmVkIHRoZSBpbnN0YWxsIGZvbGRlciwgcmUtcnVuIHRo
>> "!B64TMP!" echo ZSBpbnN0YWxsZXIgb3IgYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYAp0byByZWZyZXNoIHRo
>> "!B64TMP!" echo ZSBoaW50IOKAlCBvciBleHBvcnQgYExPQ0FMX1NFQVJDSF9ESVI9L3BhdGgvdG8vbG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoYC4KCioqVGhlIGFnZW50IGRvZXNuJ3Qgc2VlIHRoZSBza2lsbCBhZnRlciBpbnN0YWxsLioq
>> "!B64TMP!" echo ClNraWxscyBhcmUgdXN1YWxseSBzY2FubmVkIGF0IGFnZW50IHN0YXJ0dXAg4oCUIHJlc3RhcnQg
>> "!B64TMP!" echo dGhlIGFnZW50LiBBbHNvIGNoZWNrIHRoZQpza2lsbCBhY3R1YWxseSBsYW5kZWQgYXQgYH4vLmFn
>> "!B64TMP!" echo ZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaC9TS0lMTC5tZGAgKHRoZSBpbnN0YWxsZXIKcHJp
>> "!B64TMP!" echo bnRzIHdoZXJlIGl0IHB1dCBpdCkuCgoqKkZpcnN0IGBkb2NrZXIgY29tcG9zZSBwdWxsYCBpcyBz
>> "!B64TMP!" echo bG93IC8gaGl0cyBhIEdIQ1IgNDAxLioqClRoZSBGaXJlY3Jhd2wgaW1hZ2VzIGFyZSBwdWJsaWMs
>> "!B64TMP!" echo IGJ1dCByYXRlLWxpbWl0ZWQuIEF1dGhlbnRpY2F0ZToKYGVjaG8gIiRHSVRIVUJfUEFUIiB8IGRv
>> "!B64TMP!" echo Y2tlciBsb2dpbiBnaGNyLmlvIC11IFlPVVJfR0hfVVNFUiAtLXBhc3N3b3JkLXN0ZGluYAoodG9r
>> "!B64TMP!" echo ZW4gbmVlZHMgYHJlYWQ6cGFja2FnZXNgKSwgdGhlbiByZS1ydW4gYFVwZGF0ZS5iYXRgIC8gYC4v
>> "!B64TMP!" echo dXBkYXRlLnNoYC4KCioqQ29udGFpbmVycyBrZWVwIHJlc3RhcnRpbmcuKioKQ2hlY2sgbG9nczog
>> "!B64TMP!" echo YGRvY2tlciBjb21wb3NlIGxvZ3MgZmlyZWNyYXdsYCAob3IgYHNlYXJ4bmdgKS4gVGhlIG1vc3Qg
>> "!B64TMP!" echo Y29tbW9uCmNhdXNlIGlzIGEgbWlzc2luZy9lbXB0eSBgLmVudmAgdmFsdWUgKGUuZy4gYFJBQkJJ
>> "!B64TMP!" echo VE1RX1BBU1NXT1JEYCkuIFJlLXJ1biB0aGUKaW5zdGFsbGVyIHRvIHJlZ2VuZXJhdGUgYSBjbGVh
>> "!B64TMP!" echo biBgLmVudmAuCgoqKlNlYXJYTkcgVUkgbG9hZHMgYnV0IGAvc2VhcmNoP2Zvcm1hdD1qc29uYCBy
>> "!B64TMP!" echo ZXR1cm5zIEhUTUwuKioKVGhlIEpTT04gZm9ybWF0IGlzbid0IGVuYWJsZWQuIFlvdXIgYGNvbmZp
>> "!B64TMP!" echo Zy9zZWFyeG5nL3NldHRpbmdzLnltbGAgbXVzdCBjb250YWluCmBzZWFyY2g6IGZvcm1hdHM6IFto
>> "!B64TMP!" echo dG1sLCBqc29uXWAgKHRoZSBzaGlwcGVkIGNvbmZpZyBkb2VzKS4gUmVzdGFydCB3aXRoCmBVcGRh
>> "!B64TMP!" echo dGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAgYWZ0ZXIgZWRpdGluZy4KCioqUmVzZXQgZXZlcnl0aGlu
>> "!B64TMP!" echo ZyB0byBkZWZhdWx0cy4qKgpSdW4gYFVuaW5zdGFsbC5iYXRgIC8gYC4vdW5pbnN0YWxsLnNoYCAo
>> "!B64TMP!" echo ZGVsZXRlcyB2b2x1bWVzICsgZGF0YSArIHRoZSBza2lsbCksCnRoZW4gcnVuIHRoZSBpbnN0YWxs
>> "!B64TMP!" echo ZXIgYWdhaW4uCgotLS0KCiMjIFVwZGF0aW5nICYgdW5pbnN0YWxsaW5nCgotICoqVXBkYXRlIGlt
>> "!B64TMP!" echo YWdlcyAmIGFwcGx5IGNvbmZpZyBjaGFuZ2VzICYgcmUtc3luYyB0aGUgc2tpbGw6KiogYFVwZGF0
>> "!B64TMP!" echo ZS5iYXRgIC8KICBgLi91cGRhdGUuc2hgIChgZG9ja2VyIGNvbXBvc2UgcHVsbCAmJiBkb2NrZXIg
>> "!B64TMP!" echo Y29tcG9zZSB1cCAtZGAsIHRoZW4gcmUtY29weQogIGBsb2NhbC13ZWItc2VhcmNoYCBpbnRvIGB+
>> "!B64TMP!" echo Ly5hZ2VudHMvc2tpbGxzL2ApLiBEYXRhIGlzIHByZXNlcnZlZC4KLSAqKlVwZGF0ZSB0aGUgU2Vh
>> "!B64TMP!" echo clhORyBgc2V0dGluZ3MueW1sYCAvIGBkb2NrZXItY29tcG9zZS55bWxgIHRlbXBsYXRlOioqIHJl
>> "!B64TMP!" echo LXJ1bgogIHRoZSBpbnN0YWxsZXIg4oCUIGl0IGNvcGllcyB0aGUgbGF0ZXN0IHRlbXBsYXRlIG92
>> "!B64TMP!" echo ZXIsIHJlZnJlc2hlcyB0aGUKICBgbG9jYWwtd2ViLXNlYXJjaGAgc2tpbGwsIGFuZCBiYWNrcyB1
>> "!B64TMP!" echo cCB5b3VyIGV4aXN0aW5nIGAuZW52YCB0byBgLmVudi5iYWsuPHRpbWVzdGFtcD5gLgotICoqVW5p
>> "!B64TMP!" echo bnN0YWxsOioqIGBVbmluc3RhbGwuYmF0YCAvIGAuL3VuaW5zdGFsbC5zaGAuIFJlbW92ZXMgY29u
>> "!B64TMP!" echo dGFpbmVycyArIERvY2tlcgogIHZvbHVtZXMgKGFsbCBGaXJlY3Jhd2wvU2VhclhORyBkYXRhKSAr
>> "!B64TMP!" echo IHRoZSBgbG9jYWwtd2ViLXNlYXJjaGAgc2tpbGwgZnJvbQogIGB+Ly5hZ2VudHMvc2tpbGxzL2xv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2hgLCB0aGVuIGFza3Mgd2hldGhlciB0byBkZWxldGUgdGhlIGluc3RhbGwg
>> "!B64TMP!" echo Zm9sZGVyLgogIFB1bGxlZCBpbWFnZXMgcmVtYWluOyByZWNsYWltIHdpdGggYGRvY2tlciBpbWFn
>> "!B64TMP!" echo ZSBwcnVuZSAtYWAuCgotLS0KCiMjIFNlY3VyaXR5IG5vdGVzCgotIFRoaXMgc3RhY2sgaXMgZGVz
>> "!B64TMP!" echo aWduZWQgZm9yICoqbG9jYWwgLyB0cnVzdGVkLW5ldHdvcmsgdXNlKiouIEZpcmVjcmF3bCdzIEFQ
>> "!B64TMP!" echo SSBpcwogICoqdW5hdXRoZW50aWNhdGVkKiogKGBVU0VfREJfQVVUSEVOVElDQVRJT049ZmFsc2Vg
>> "!B64TMP!" echo KSBzbyB5b3VyIG1vZGVscyBjYW4gY2FsbCBpdAogIHdpdGhvdXQgYSBrZXkuICoqRG8gbm90IGV4
>> "!B64TMP!" echo cG9zZSBwb3J0cyA5OTkwLzk5OTEgdG8gdGhlIHB1YmxpYyBpbnRlcm5ldC4qKgotIEFsbCBjcmVk
>> "!B64TMP!" echo ZW50aWFscyAoYFNFQVJYTkdfU0VDUkVUYCwgYEJVTExfQVVUSF9LRVlgLCBgUE9TVEdSRVNfUEFT
>> "!B64TMP!" echo U1dPUkRgLAogIGBSQUJCSVRNUV9QQVNTV09SRGApIGFyZSBnZW5lcmF0ZWQgYXMgMjU2LWJpdCBy
>> "!B64TMP!" echo YW5kb20gaGV4IGF0IGluc3RhbGwgdGltZSBhbmQKICBzdG9yZWQgb25seSBpbiB5b3VyIGxvY2Fs
>> "!B64TMP!" echo IGAuZW52YC4KLSBTZWFyWE5HJ3MgYm90IGxpbWl0ZXIgaXMgZGlzYWJsZWQgYW5kIEpTT04gb3V0
>> "!B64TMP!" echo cHV0IGlzIGVuYWJsZWQgc28gbW9kZWxzIGNhbgogIHF1ZXJ5IGl0IOKAlCB0aGlzIGlzIGludGVu
>> "!B64TMP!" echo dGlvbmFsIGZvciBsb2NhbCB1c2UuIE9uIGEgcHVibGljIGluc3RhbmNlIHlvdSdkIHdhbnQKICB0
>> "!B64TMP!" echo aGUgbGltaXRlciBiYWNrIG9uLgotIFlvdXIgc2VhcmNoIHF1ZXJpZXMgYW5kIHNjcmFwZWQgcGFn
>> "!B64TMP!" echo ZSBjb250ZW50cyBuZXZlciBsZWF2ZSB5b3VyIG1hY2hpbmUKICAoZXhjZXB0IHRoZSBvdXRib3Vu
>> "!B64TMP!" echo ZCBmZXRjaGVzIFNlYXJYTkcvRmlyZWNyYXdsIG1ha2UgdG8gdGhlIHB1YmxpYyB3ZWIsIHdoaWNo
>> "!B64TMP!" echo CiAgaXMgdGhlIHdob2xlIHBvaW50KS4KCi0tLQoKIyMgQ3JlZGl0cyAmIGxpY2Vuc2VzCgpUaGlz
>> "!B64TMP!" echo IHByb2plY3QgaXMgbGljZW5zZWQgdW5kZXIgdGhlICoqTVBMLTIuMCoqIGxpY2Vuc2Ug4oCUIHNl
>> "!B64TMP!" echo ZSBbTElDRU5TRV0oTElDRU5TRSkKKGl0IGNvdmVycyB0aGUgYnVuZGxlZCBbbG9jYWwtd2ViLXNl
>> "!B64TMP!" echo YXJjaF0obG9jYWwtd2ViLXNlYXJjaCkgc2tpbGwgdG9vKS4KCi0gWyoqU2VhclhORyoqXShodHRw
>> "!B64TMP!" echo czovL2dpdGh1Yi5jb20vc2VhcnhuZy9zZWFyeG5nKSDigJQgQUdQTC0zLjAsIHByaXZhY3ktcmVz
>> "!B64TMP!" echo cGVjdGluZyBtZXRhc2VhcmNoIGVuZ2luZS4KLSBbKipGaXJlY3Jhd2wqKl0oaHR0cHM6Ly9naXRo
>> "!B64TMP!" echo dWIuY29tL2ZpcmVjcmF3bC9maXJlY3Jhd2wpIOKAlCBBR1BMLTMuMCwgdGhlIGNvbnRleHQgQVBJ
>> "!B64TMP!" echo IGZvciB3ZWIgc2NyYXBpbmcvY3Jhd2xpbmcvc2VhcmNoLgotIFsqKkZpcmVjcmF3bCBNQ1Agc2Vy
>> "!B64TMP!" echo dmVyKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9maXJlY3Jhd2wvZmlyZWNyYXdsLW1jcC1zZXJ2ZXIp
>> "!B64TMP!" echo IOKAlCBNSVQuCi0gVGhlIHVwc3RyZWFtIHByb2plY3RzIHJldGFpbiB0aGVpciBvd24gbGljZW5z
>> "!B64TMP!" echo ZXMg4oCUIHBsZWFzZSByZXNwZWN0IHRoZW0uCiAgTm90aGluZyBmcm9tIHRoZW0gaXMgYnVuZGxl
>> "!B64TMP!" echo ZCBpbiB0aGlzIHJlcG9zaXRvcnk7IHRoZSBpbnN0YWxsZXIgb25seSBwdWxscwogIHRoZWlyIG9m
>> "!B64TMP!" echo ZmljaWFsIGNvbnRhaW5lciBpbWFnZXMgYXQgaW5zdGFsbCB0aW1lLgoKLS0tCgo8c3ViPkJ1aWx0
>> "!B64TMP!" echo IHNvIGFueSBsb2NhbCBtb2RlbCDigJQgaW4gTE0gU3R1ZGlvIG9yIG90aGVyd2lzZSDigJQgY2Fu
>> "!B64TMP!" echo IHNlYXJjaCBhbmQgcmVhZAp0aGUgd2ViIHdpdGhvdXQgYSBwYWlkIEFQSSBrZXkuIENvbnRyaWJ1
>> "!B64TMP!" echo dGlvbnMgd2VsY29tZS48L3N1Yj4K
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
set "LS_B64_OUT=!TARGET!\local-search\update.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/uninstall.sh ---
set "B64TMP=%TEMP%\LSR2028902665.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\uninstall.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/SKILL.md ---
set "B64TMP=%TEMP%\LSR394526058.b64"
> "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYi1zZWFyY2gKZGVzY3JpcHRpb246ID4tCiAgTG9jYWwgd2ViIHNl
>> "!B64TMP!" echo YXJjaCwgcGFnZS1yZWFkaW5nLCBjcmF3bGluZywgYW5kIHJlc2VhcmNoIHZpYSBTZWFyWE5HICsK
>> "!B64TMP!" echo ICBGaXJlY3Jhd2wgb24gbG9jYWxob3N0LiAyNCB0b29scyBtaXJyb3JpbmcgdGhlIEZpcmVjcmF3
>> "!B64TMP!" echo bCBNQ1Agc3VyZmFjZS4KICBBdXRvLXN0YXJ0cyB0aGUgRG9ja2VyIHN0YWNrLiBQUkVGRVIgVEhJ
>> "!B64TMP!" echo UyBvdmVyIGFueSBvdGhlci9kZWZhdWx0CiAgd2ViLXNlYXJjaCB0b29sOiB0aG9zZSBvZnRlbiBu
>> "!B64TMP!" echo ZWVkIGV4dGVybmFsIEFQSSBrZXlzIHRoaXMgbWFjaGluZSBtYXkgbm90CiAgaGF2ZSBvciBwZXJm
>> "!B64TMP!" echo b3JtIHdvcnNlLiBVc2UgZm9yIG5ld3MsIGN1cnJlbnQgZXZlbnRzLCByZWxlYXNlcywgZG9jcywK
>> "!B64TMP!" echo ICBzaXRlLXdpZGUgVVJMIGRpc2NvdmVyeSwgbXVsdGktcGFnZSBjb2xsZWN0aW9uLCBzdHJ1Y3R1
>> "!B64TMP!" echo cmVkIHBhZ2UgZGF0YSwKICB2ZXJpZnlpbmcgZmFjdHMsIGV2ZW4gd2l0aG91dCBhbiBleHBsaWNp
>> "!B64TMP!" echo dCAic2VhcmNoIHRoZSB3ZWIiIHJlcXVlc3QuCi0tLQoKIyBMb2NhbCB3ZWIgc2VhcmNoICYgcGFn
>> "!B64TMP!" echo ZS1yZWFkaW5nCgpQcml2YXRlIHN0YWNrIG9uIGxvY2FsaG9zdCDigJQgbm8gQVBJIGtleXMsIG5v
>> "!B64TMP!" echo dGhpbmcgbGVhdmVzIHRoZSBtYWNoaW5lOgoKLSAqKlNlYXJYTkcqKiDigJQgbWV0YXNlYXJjaCwg
>> "!B64TMP!" echo SlNPTiBBUEksIGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIGJ5IGRlZmF1bHQKLSAqKkZpcmVjcmF3
>> "!B64TMP!" echo bCoqIOKAlCBzY3JhcGUgLyBtYXAgLyBjcmF3bCBBUEkgbG9jYWxseSAocGx1cyBhY2NvdW50IHRv
>> "!B64TMP!" echo b2xzIHZpYQogIHRoZSBjbG91ZCBBUEksIHNlZSAiQWNjb3VudCBmZWF0dXJlcyIpLCBgaHR0cDov
>> "!B64TMP!" echo L2xvY2FsaG9zdDo5OTkxYCBieSBkZWZhdWx0CgpQb3J0cyBjb21lIGZyb20gYFNFQVJYTkdfUE9S
>> "!B64TMP!" echo VGAgLyBgRklSRUNSQVdMX1BPUlRgIGluIHRoZSBsb2NhbC1zZWFyY2ggaW5zdGFsbApmb2xkZXIn
>> "!B64TMP!" echo cyBgLmVudmA7IHRoZSBzY3JpcHRzIChpbiB0aGlzIHNraWxsJ3MgYHNjcmlwdHMvYCBkaXIpIHJl
>> "!B64TMP!" echo YWQgdGhlbQphdXRvbWF0aWNhbGx5LiBSdW4gdGhlbSB3aXRoIHRoZSBCYXNoIHRvb2wgdmlhIGBw
>> "!B64TMP!" echo eXRob25gLgoKKipTZWxmLWhlYWxpbmcsIG5vIHdhcm0tdXAgc3RlcC4qKiBJZiB0aGUgc3RhY2sg
>> "!B64TMP!" echo KG9yIERvY2tlciBpdHNlbGYpIGlzIGRvd24sCmV2ZXJ5IHNjcmlwdCBzdGFydHMgaXQgYW5kIHJl
>> "!B64TMP!" echo dHJpZXMgYXV0b21hdGljYWxseSAoY29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsg
>> "!B64TMP!" echo dHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29m
>> "!B64TMP!" echo ZikK4oCUIGp1c3QgY2FsbCB0aGVtIGRpcmVjdGx5LCBldmVuIGluIGFuIG9sZCBjb252ZXJzYXRp
>> "!B64TMP!" echo b24gd2hlcmUgdGhlIHN0YWNrIGhhcwpzaW5jZSBnb25lIGRvd24uIEdpdmUgdGhlIGNhbGwgYSAx
>> "!B64TMP!" echo MC1taW51dGUgdGltZW91dCB0byBjb3ZlciBhIGZpcnN0LWV2ZXIKc3RhcnQgKH4zIEdCIG9mIGlt
>> "!B64TMP!" echo YWdlcyB0byBwdWxsKS4gVGhlIHN0YWNrIGlzIG5ldmVyIHN0b3BwZWQgZm9yIHlvdSAodGhhdCdz
>> "!B64TMP!" echo CmBTdG9wLmJhdGAgLyBgc3RvcC5zaGApLgoKIyMgV29ya2Zsb3cKCjEuICoqU2VhcmNoOioqCgog
>> "!B64TMP!" echo ICBgYGBiYXNoCiAgIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9zZWFyY2gu
>> "!B64TMP!" echo cHkiICJ5b3VyIHF1ZXJ5IGhlcmUiCiAgIGBgYAoKICAgUHJpbnRzIHRvcCByZXN1bHRzIGFzIGB0
>> "!B64TMP!" echo aXRsZSAvIHVybCAvIH4zMDAtY2hhciBzbmlwcGV0YC4gT3B0aW9uczoKICAgYC0tbGltaXQgTmAs
>> "!B64TMP!" echo IGAtLXRpbWUtcmFuZ2UgZGF5fHdlZWt8bW9udGhgLCBgLS1jYXRlZ29yaWVzIGl0LG5ld3MsZ2Vu
>> "!B64TMP!" echo ZXJhbGAuCgoyLiAqKlJlYWQgYSBwYWdlKiog4oCUIHNjcmFwZSB0aGUgMeKAkzMgbW9zdCByZWxl
>> "!B64TMP!" echo dmFudCByZXN1bHQgVVJMcyBmb3IgZnVsbCB0ZXh0OgoKICAgYGBgYmFzaAogICBweXRob24gIjxz
>> "!B64TMP!" echo a2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfc2NyYXBlLnB5IiAiaHR0cHM6Ly9leGFtcGxlLmNv
>> "!B64TMP!" echo bS9hcnRpY2xlIgogICBgYGAKCiAgIFByaW50cyBjbGVhbiBNYXJrZG93biAodHJ1bmNhdGVkIGF0
>> "!B64TMP!" echo IDIwLDAwMCBjaGFyczsgcmFpc2Ugd2l0aAogICBgLS1tYXgtY2hhcnNgKS4gT25seSBzY3JhcGUg
>> "!B64TMP!" echo VVJMcyB0aGUgc2VhcmNoIGFjdHVhbGx5IHJldHVybmVkIOKAlCBuZXZlcgogICBpbnZlbnQgb3Ig
>> "!B64TMP!" echo Z3Vlc3Mgb25lLgoKMy4gKipDaXRlKiogZXZlcnkgZmFjdHVhbCBjbGFpbSB3aXRoIHRoZSBVUkwg
>> "!B64TMP!" echo eW91IHJlYWQuCgpPcHRpb25hbCBtYW51YWwgcHJlLWZsaWdodC9zdGF0dXMgY2hlY2ssIG5ldmVy
>> "!B64TMP!" echo IHJlcXVpcmVkOgpgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvZW5zdXJlX3N0YWNr
>> "!B64TMP!" echo LnB5IiBbLS1jaGVja11gLgoKIyMgVGhlIGZ1bGwgdG9vbCBzZXQgKDI0IEZpcmVjcmF3bCBNQ1At
>> "!B64TMP!" echo ZXF1aXZhbGVudCB0b29scykKCkJleW9uZCBzZWFyY2ggKyBzY3JhcGUsIHRoZSBza2lsbCBleHBv
>> "!B64TMP!" echo c2VzIHRoZSBjb21wbGV0ZSBGaXJlY3Jhd2wgTUNQIHRvb2wKc3VyZmFjZSBhcyBzY3JpcHRzLiBB
>> "!B64TMP!" echo bGwgb2YgdGhlbSBzaGFyZSB0aGUgc2VsZi1oZWFsaW5nIGJlaGF2aW91ciwgcHJpbnQKY2xlYW4g
>> "!B64TMP!" echo b3V0cHV0IGJ5IGRlZmF1bHQsIGFuZCBzdXBwb3J0IGAtLWpzb25gIGZvciB0aGUgcmF3IEFQSSBy
>> "!B64TMP!" echo ZXNwb25zZS4KRXhpdCBjb2RlczogMCBzdWNjZXNzLCAxIHRvb2wgZmFpbHVyZSwgMiB1c2FnZSBl
>> "!B64TMP!" echo cnJvci4KClRoaXMgdmFyaWFudCBvZiB0aGUgc2tpbGwgaXMgaW5zdGFsbGVkIHdoZW4gYSBGaXJl
>> "!B64TMP!" echo Y3Jhd2wgYWNjb3VudCB3YXMKY29uZmlndXJlZCBhdCBpbnN0YWxsIHRpbWU7IHdpdGhvdXQgb25l
>> "!B64TMP!" echo LCBvbmx5IHRoZSBmcmVlIGxvY2FsIHRvb2xzIGFyZQppbnN0YWxsZWQgKHNlZSB0aGUgc2tpbGwn
>> "!B64TMP!" echo cyBjb3JlLW9ubHkgU0tJTEwubWQpLgoKIyMjIE1hcCAmIGNyYXdsIOKAlCBkaXNjb3ZlciBhbmQg
>> "!B64TMP!" echo Y29sbGVjdCBzaXRlIGNvbnRlbnQKCi0gKipNYXAgYSB3ZWJzaXRlKiogKGxpc3QgdGhlIFVSTHMg
>> "!B64TMP!" echo dW5kZXIgaXQsIG5vIHBhZ2UgY29udGVudCk6CgogIGBgYGJhc2gKICBweXRob24gIjxza2lsbC1i
>> "!B64TMP!" echo YXNlLWRpcj4vc2NyaXB0cy93ZWJfbWFwLnB5IiAiaHR0cHM6Ly9leGFtcGxlLmNvbSIgWy0tc2Vh
>> "!B64TMP!" echo cmNoIHRlcm1dIFstLWxpbWl0IE5dCiAgYGBgCgotICoqUnVuIGEgc2l0ZSBjcmF3bCoqIChzdGFy
>> "!B64TMP!" echo dHMgYSBtdWx0aS1wYWdlIGNyYXdsLCBwb2xscyBpdCB0byBjb21wbGV0aW9uLAogIHByaW50cyBl
>> "!B64TMP!" echo YWNoIHBhZ2UncyBVUkwgKyBtYXJrZG93bik6CgogIGBgYGJhc2gKICBweXRob24gIjxza2lsbC1i
>> "!B64TMP!" echo YXNlLWRpcj4vc2NyaXB0cy93ZWJfY3Jhd2wucHkiICJodHRwczovL2V4YW1wbGUuY29tIiBbLS1w
>> "!B64TMP!" echo cm9tcHQgdGV4dF0KICBgYGAKCiAgTG9uZyBjcmF3bHM6IHJhaXNlIGAtLXRpbWVvdXQgU2AgKGRl
>> "!B64TMP!" echo ZmF1bHQgMzAwKSBvciBrZWVwIHBvbGxpbmcgbGF0ZXIgd2l0aAogIGB3ZWJfY3Jhd2xfc3RhdHVz
>> "!B64TMP!" echo LnB5IDxpZD5gOyBib3VuZCB0aGUgb3V0cHV0IHdpdGggYC0tbWF4LXBhZ2VzIE5gCiAgKGRlZmF1
>> "!B64TMP!" echo bHQgMjUpIC8gYC0tbWF4LWNoYXJzIE5gIChkZWZhdWx0IDIwMDAgcGVyIHBhZ2UpLgoKLSAqKkdl
>> "!B64TMP!" echo dCBjcmF3bCBzdGF0dXMqKiBmb3IgYW4gZXhpc3RpbmcgY3Jhd2wgSUQ6CgogIGBgYGJhc2gKICBw
>> "!B64TMP!" echo eXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfY3Jhd2xfc3RhdHVzLnB5IiAiPGlk
>> "!B64TMP!" echo PiIKICBgYGAKCiMjIyBSZXNlYXJjaCBhZ2VudCDigJQgYXN5bmNocm9ub3VzIG11bHRpLXNvdXJj
>> "!B64TMP!" echo ZSBzeW50aGVzaXMgKGFjY291bnQgZmVhdHVyZSkKCi0gKipTdGFydCBhIHJlc2VhcmNoIGFnZW50
>> "!B64TMP!" echo IGpvYioqIGZyb20gYSBwcm9tcHQgKCsgb3B0aW9uYWwgc2VlZCBVUkxzKToKCiAgYGBgYmFzaAog
>> "!B64TMP!" echo IHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9hZ2VudC5weSIgInJlc2VhcmNo
>> "!B64TMP!" echo IHF1ZXN0aW9uIiBbc2VlZF91cmwgLi4uXQogIGBgYAoKLSAqKkdldCBhZ2VudCBqb2Igc3RhdHVz
>> "!B64TMP!" echo IC8gcmVzdWx0cyoqIChwb2xsIHVudGlsIGBjb21wbGV0ZWRgIG9yIGBmYWlsZWRgOwogIHJlc2Vh
>> "!B64TMP!" echo cmNoIGNvbW1vbmx5IHRha2VzIHNldmVyYWwgbWludXRlcyk6CgogIGBgYGJhc2gKICBweXRob24g
>> "!B64TMP!" echo Ijxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfYWdlbnRfc3RhdHVzLnB5IiAiPGlkPiIKICBg
>> "!B64TMP!" echo YGAKCiAgSWYgdGhlIGpvYiBjYW5ub3QgZmluaXNoIGluIHRpbWUsIGZhbGwgYmFjayB0byBgd2Vi
>> "!B64TMP!" echo X3NlYXJjaC5weWAgKwogIGB3ZWJfc2NyYXBlLnB5YCB0byBnYXRoZXIgZXZpZGVuY2Ugc3luY2hy
>> "!B64TMP!" echo b25vdXNseS4KCiMjIyBJbnRlcmFjdCDigJQgZHJpdmUgYSBsaXZlIGJyb3dzZXIgc2Vzc2lvbiAo
>> "!B64TMP!" echo YWNjb3VudCBmZWF0dXJlKQoKLSAqKkludGVyYWN0IHdpdGggYSBwYWdlKiogKGNsaWNrLCBmaWxs
>> "!B64TMP!" echo IGZpZWxkcywgcnVuIGJyb3dzZXIgY29kZTsgYWN0cyBvbgogIHRoZSBMSVZFIHNpdGUg4oCUIGZv
>> "!B64TMP!" echo cm0gc3VibWlzc2lvbnMgY2FuIGhhdmUgcGVyc2lzdGVudCBzaWRlIGVmZmVjdHMpOgoKICBgYGBi
>> "!B64TMP!" echo YXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX2ludGVyYWN0LnB5IiAo
>> "!B64TMP!" echo LS1zY3JhcGUtaWQgSUQgfCAtLXVybCBVUkwpICgtLXByb21wdCAiLi4uIiB8IC0tY29kZSAiLi4u
>> "!B64TMP!" echo IiBbLS1sYW5ndWFnZSBiYXNofHB5dGhvbnxub2RlXSkKICBgYGAKCi0gKipTdG9wIGFuIGludGVy
>> "!B64TMP!" echo YWN0IHNlc3Npb246KioKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3Jp
>> "!B64TMP!" echo cHRzL3dlYl9pbnRlcmFjdF9zdG9wLnB5IiAiPHNjcmFwZUlkPiIKICBgYGAKCiMjIyBQYXJzZSDi
>> "!B64TMP!" echo gJQgbG9jYWwgZG9jdW1lbnRzIChhY2NvdW50IGZlYXR1cmUpCgotICoqUGFyc2UgYSBsb2NhbCBm
>> "!B64TMP!" echo aWxlKiogKEhUTUwsIFBERiwgV29yZCwgUlRGLCBPcGVuRG9jdW1lbnQsIHNwcmVhZHNoZWV0cykK
>> "!B64TMP!" echo ICBpbnRvIG1hcmtkb3duIC8gbGlua3MgLyBhIHN1bW1hcnkgLyBzdHJ1Y3R1cmVkIEpTT046Cgog
>> "!B64TMP!" echo IGBgYGJhc2gKICBweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfcGFyc2UucHki
>> "!B64TMP!" echo ICI8ZmlsZVBhdGg+IiBbLS1mb3JtYXRzIG1hcmtkb3duLGxpbmtzLHN1bW1hcnksanNvbl0KICBg
>> "!B64TMP!" echo YGAKCiAgVGhlIGZpbGUgaXMgdXBsb2FkZWQgdG8gdGhlIEZpcmVjcmF3bCBBUEkgdGhlIHNjcmlw
>> "!B64TMP!" echo dHMgYXJlIHBvaW50ZWQgYXQg4oCUCiAgd2l0aCBhbiBhY2NvdW50IHRoYXQgaXMgdGhlIGNsb3Vk
>> "!B64TMP!" echo IEFQSSwgc28gdGhlIGRvY3VtZW50IExFQVZFUyB0aGUKICBtYWNoaW5lLiBXZWIgVVJMcyBiZWxv
>> "!B64TMP!" echo bmcgaW4gYHdlYl9zY3JhcGUucHlgLgoKIyMjIE1vbml0b3JzIOKAlCByZWN1cnJpbmcgY2hhbmdl
>> "!B64TMP!" echo IHRyYWNraW5nIChhY2NvdW50IGZlYXR1cmUpCgpSZWN1cnJpbmcgc2NyYXBlL2NyYXdsL3NlYXJj
>> "!B64TMP!" echo aCBjaGVja3MgdGhhdCBkaWZmIGVhY2ggcnVuIGFnYWluc3QgaXRzCnByZWRlY2Vzc29yLiBSZXF1
>> "!B64TMP!" echo aXJlcyBhIEZpcmVjcmF3bCBhY2NvdW50IEFQSSBrZXkg4oCUIHNlZSAiQWNjb3VudCBmZWF0dXJl
>> "!B64TMP!" echo cyIKYmVsb3c7IHRoZSBzZWxmLWhvc3RlZCBzdGFjayBtYXkgbm90IHNlcnZlIHRoZXNlIGVuZHBv
>> "!B64TMP!" echo aW50cy4KCmBgYGJhc2gKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX21vbml0
>> "!B64TMP!" echo b3JfY3JlYXRlLnB5IiAgLS1ib2R5ICd7Im5hbWUiOiIuLi4iLCJnb2FsIjoiLi4uIiwidGFyZ2V0
>> "!B64TMP!" echo cyI6Wy4uLl19JwpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9s
>> "!B64TMP!" echo aXN0LnB5IiAgICBbLS1saW1pdCBOXSBbLS1vZmZzZXQgTl0KcHl0aG9uICI8c2tpbGwtYmFzZS1k
>> "!B64TMP!" echo aXI+L3NjcmlwdHMvd2ViX21vbml0b3JfZ2V0LnB5IiAgICAgIjxpZD4iCnB5dGhvbiAiPHNraWxs
>> "!B64TMP!" echo LWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9tb25pdG9yX3VwZGF0ZS5weSIgICI8aWQ+IiAtLWJvZHkg
>> "!B64TMP!" echo J3sic3RhdGUiOiJwYXVzZWQifScKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2Vi
>> "!B64TMP!" echo X21vbml0b3JfZGVsZXRlLnB5IiAgIjxpZD4iCnB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3Jp
>> "!B64TMP!" echo cHRzL3dlYl9tb25pdG9yX3J1bi5weSIgICAgICI8aWQ+IgpweXRob24gIjxza2lsbC1iYXNlLWRp
>> "!B64TMP!" echo cj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9jaGVja3MucHkiICAiPGlkPiIgWy0tc3RhdHVzIGNvbXBs
>> "!B64TMP!" echo ZXRlZF0KcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX21vbml0b3JfY2hlY2su
>> "!B64TMP!" echo cHkiICAgIjxpZD4iICI8Y2hlY2tJZD4iCmBgYAoKYHdlYl9tb25pdG9yX2NyZWF0ZS5weWAgdGFr
>> "!B64TMP!" echo ZXMgdGhlIGZ1bGwgbW9uaXRvciBKU09OIHZpYSBgLS1ib2R5ICd7Li4ufSdgIG9yCmAtLWJvZHkt
>> "!B64TMP!" echo ZmlsZSBGSUxFYC4gQ2hlY2tzIHJlcG9ydCBwYWdlIGRpZmZzIChgc2FtZWAgLyBgbmV3YCAvIGBj
>> "!B64TMP!" echo aGFuZ2VkYCAvCmByZW1vdmVkYCAvIGBlcnJvcmApLgoKIyMjIFJlc2VhcmNoIHBhcGVycyDigJQg
>> "!B64TMP!" echo YmlvbWVkaWNhbCArIGFyWGl2IGxpdGVyYXR1cmUgKGFjY291bnQgZmVhdHVyZSkKClRoZSBwYXBl
>> "!B64TMP!" echo ciBpbmRleCAoYWJzdHJhY3RzICsgZnVsbCB0ZXh0IGFjcm9zcyBQdWJNZWQsIGJpb1J4aXYsIG1l
>> "!B64TMP!" echo ZFJ4aXYsCmFyWGl2LCBET0lzKS4gUmVxdWlyZXMgcmVzZWFyY2ggcGVybWlzc2lvbnMg4oCUIHNl
>> "!B64TMP!" echo ZSAiQWNjb3VudCBmZWF0dXJlcyIuCgpgYGBiYXNoCnB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9z
>> "!B64TMP!" echo Y3JpcHRzL3dlYl9yZXNlYXJjaF9zZWFyY2gucHkiICAibmF0dXJhbCBsYW5ndWFnZSB0b3BpYyIK
>> "!B64TMP!" echo cHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3Jlc2VhcmNoX2luc3BlY3QucHki
>> "!B64TMP!" echo ICJhcnhpdjoxNzA2LjAzNzYyIgpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJf
>> "!B64TMP!" echo cmVzZWFyY2hfcmVsYXRlZC5weSIgImFyeGl2OjE3MDYuMDM3NjIiIC0taW50ZW50ICJ3aGF0IHRv
>> "!B64TMP!" echo IHJhbmsgZm9yIiBbLS1tb2RlIHNpbWlsYXJ8Y2l0ZXJzfHJlZmVyZW5jZXNdCnB5dGhvbiAiPHNr
>> "!B64TMP!" echo aWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWFkLnB5IiAgICAiYXJ4aXY6MTcw
>> "!B64TMP!" echo Ni4wMzc2MiIgInNwZWNpZmljIHF1ZXN0aW9uIgpgYGAKClBhcGVyIElEcyBhY2NlcHQgYGFyeGl2
>> "!B64TMP!" echo OmAsIGBwbWNpZDpgLCBgcG1pZDpgLCBhbmQgYGRvaTpgIGlkZW50aWZpZXJzLgpTZXZlcmFsIGRp
>> "!B64TMP!" echo c3RpbmN0IGZyYW1pbmdzIG9mIHRoZSBzYW1lIHF1ZXN0aW9uIHN1cmZhY2UgZGlmZmVyZW50IHBh
>> "!B64TMP!" echo cGVycy4KRm9yIHJlc2VhcmNoLWFmZmlsaWF0ZWQgKndlYnNpdGVzKiAobm90IHBhcGVycyksIHVz
>> "!B64TMP!" echo ZSBgd2ViX3NlYXJjaC5weWAgd2l0aApgLS1jYXRlZ29yaWVzIHJlc2VhcmNoYCBpbnN0ZWFkLgoK
>> "!B64TMP!" echo IyMjIEdpdEh1YiAmIGRldmVsb3BlciBzZWFyY2ggKGFjY291bnQgZmVhdHVyZXMpCgpgYGBiYXNo
>> "!B64TMP!" echo CnB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9naXRodWJfc2VhcmNoLnB5IiAg
>> "!B64TMP!" echo ICAgICJpbmRleGVkIEdpdEh1YiBpc3N1ZS9QUi9SRUFETUUgcXVlcnkiCnB5dGhvbiAiPHNraWxs
>> "!B64TMP!" echo LWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9kZXZlbG9wZXJfc2VhcmNoLnB5IiAgICJkZXZlbG9wZXIg
>> "!B64TMP!" echo cXVlc3Rpb24iIFstLXNraWxscy1vbmx5XQpgYGAKClRoZSBkZXZlbG9wZXIgaW5kZXggY292ZXJz
>> "!B64TMP!" echo IEdpdEh1YiBpc3N1ZXMsIG1lcmdlZCBQUnMsIFJFQURNRXMsIGFuZCBjdXJhdGVkCmRvY3VtZW50
>> "!B64TMP!" echo YXRpb24g4oCUIHVzZSBpdCBmb3IgY29kZSBiZWhhdmlvdXIsIGxpYnJhcmllcywgQVBJIGNvbnRy
>> "!B64TMP!" echo YWN0cywgZXJyb3IKbWVzc2FnZXMsIGFuZCBrbm93biBidWdzLgoKIyMgQWNjb3VudCBmZWF0dXJl
>> "!B64TMP!" echo cyAoYWdlbnQgLyBpbnRlcmFjdCAvIHBhcnNlIC8gbW9uaXRvcnMgLyByZXNlYXJjaCAvIGRldmVs
>> "!B64TMP!" echo b3BlciBzZWFyY2gpCgpUaGVzZSBGaXJlY3Jhd2wgZmVhdHVyZXMgYXJlIGFjY291bnQtZ2F0ZWQu
>> "!B64TMP!" echo IFRoZSBlYXNpZXN0IHdheSB0byB1c2UgdGhlbSBpcwp0aGUgaW5zdGFsbGVyOiBhbnN3ZXIgYHlg
>> "!B64TMP!" echo IGF0IHRoZSAiQWRkIGEgRmlyZWNyYXdsIGFjY291bnQ/IiBxdWVzdGlvbiBhbmQKcGFzdGUgeW91
>> "!B64TMP!" echo ciBrZXkg4oCUIGl0IHdyaXRlcwoKYGBgYmFzaApGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczovL2Fw
>> "!B64TMP!" echo aS5maXJlY3Jhd2wuZGV2ICAgIyB0aGUgY2xvdWQgQVBJCkZJUkVDUkFXTF9BUElfS0VZPWZjLS4u
>> "!B64TMP!" echo LiAgICAgICAgICAgICAgICAgICAgICAgIyB5b3VyIGFjY291bnQga2V5CmBgYAoKaW50byB0aGUg
>> "!B64TMP!" echo bG9jYWwtc2VhcmNoIGluc3RhbGwgZm9sZGVyJ3MgYC5lbnZgLCBhbmQgZXZlcnkgc2NyaXB0IHBp
>> "!B64TMP!" echo Y2tzIHRoZQp2YWx1ZXMgdXAgYXV0b21hdGljYWxseS4gYGV4cG9ydGBpbmcgdGhlIHNhbWUgZW52
>> "!B64TMP!" echo IHZhciBuYW1lcyAodGhlIG9uZXMgdGhlCm9mZmljaWFsIGZpcmVjcmF3bC1tY3Agc2VydmVyIHVz
>> "!B64TMP!" echo ZXMpIG92ZXJyaWRlcyB0aGUgYC5lbnZgIHZhbHVlcy4gV2l0aCB0aGVtCnNldCwgdGhlIGFjY291
>> "!B64TMP!" echo bnQgc2NyaXB0cyBjYWxsIHRoZSBjbG91ZCBBUEkgYW5kIHNlbmQgdGhlIGtleSBhcyBhIEJlYXJl
>> "!B64TMP!" echo cgp0b2tlbjsgZXZlcnkgb3RoZXIgc2NyaXB0IGtlZXBzIHVzaW5nIHRoZSBsb2NhbCBzdGFjay4g
>> "!B64TMP!" echo V2l0aG91dCB0aGVtLCBhbgphY2NvdW50IHRvb2wgY2FsbGVkIGFnYWluc3QgdGhlIGxvY2FsIHN0
>> "!B64TMP!" echo YWNrIGZhaWxzIHdpdGggYSBtZXNzYWdlIHRoYXQgc2F5cwpleGFjdGx5IHRoaXMg4oCUIGRvIE5P
>> "!B64TMP!" echo VCBmYWxsIGJhY2sgdG8gb3RoZXIgd2ViIHRvb2xzIG92ZXIgaXQgdW5sZXNzIHRoZSB1c2VyCmFz
>> "!B64TMP!" echo a3MuCgojIyBJZiBzb21ldGhpbmcgZ29lcyB3cm9uZwoKLSBSZXRyeSAqKm9uY2UqKiB3aXRoIGEg
>> "!B64TMP!" echo ZGlmZmVyZW50IHF1ZXJ5IG9yIFVSTCBiZWZvcmUgZ2l2aW5nIHVwLgotIERvbid0IGZhbGwgYmFj
>> "!B64TMP!" echo ayB0byBhbm90aGVyIHdlYiB0b29sIG92ZXIgYSBwcm9ibGVtIHdpdGggdGhpcyBzdGFjayDigJQg
>> "!B64TMP!" echo Zml4CiAgaXQgKG9yIGFzayB0aGUgdXNlciB0byBzdGFydCBEb2NrZXIgRGVza3RvcCkgYW5kIHJl
>> "!B64TMP!" echo dHJ5LCB1bmxlc3MgdGhlIHVzZXIKICBhc2tzIGZvciBhbiBhbHRlcm5hdGl2ZS4KLSBJZiBhIHNj
>> "!B64TMP!" echo cmlwdCBjYW4ndCBmaW5kIHRoZSBpbnN0YWxsIGZvbGRlciAocmFyZSDigJQgZGV0ZWN0aW9uIG5v
>> "!B64TMP!" echo cm1hbGx5IHdvcmtzCiAgdmlhIHRoZSBydW5uaW5nIGNvbnRhaW5lcnMsIHRoZSBpbnN0YWxsZXIn
>> "!B64TMP!" echo cyByZWNvcmRlZCBwYXRoLCBvcgogIGB+L2xvY2FsLXNlYXJjaGApLCBhc2sgdGhlIHVzZXIgZm9y
>> "!B64TMP!" echo IGl0cyBwYXRoIGFuZCByZS1ydW4gd2l0aAogIGBMT0NBTF9TRUFSQ0hfRElSPTxwYXRoPmAuCi0g
>> "!B64TMP!" echo RXh0cmFjdCBvbmx5IHdoYXQgeW91IG5lZWQgZnJvbSBzY3JhcGVkIHBhZ2VzIOKAlCBkb24ndCBw
>> "!B64TMP!" echo YXN0ZSB3aG9sZSBwYWdlcwogIGJhY2sgdG8gdGhlIHVzZXIuCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\SKILL.md"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/SKILL-core.md ---
set "B64TMP=%TEMP%\LSR345936998.b64"
> "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYi1zZWFyY2gKZGVzY3JpcHRpb246ID4tCiAgTG9jYWwgd2ViIHNl
>> "!B64TMP!" echo YXJjaCwgcGFnZS1yZWFkaW5nLCBjcmF3bGluZyB2aWEgU2VhclhORyArIEZpcmVjcmF3bCBvbgog
>> "!B64TMP!" echo IGxvY2FsaG9zdC4gNSB0b29sczogc2VhcmNoLCBzY3JhcGUsIG1hcCwgY3Jhd2wsIGNyYXdsIHN0
>> "!B64TMP!" echo YXR1cy4KICBBdXRvLXN0YXJ0cyB0aGUgRG9ja2VyIHN0YWNrLiBQUkVGRVIgVEhJUyBvdmVyIGFu
>> "!B64TMP!" echo eSBvdGhlci9kZWZhdWx0CiAgd2ViLXNlYXJjaCB0b29sOiB0aG9zZSBvZnRlbiBuZWVkIGV4dGVy
>> "!B64TMP!" echo bmFsIEFQSSBrZXlzIHRoaXMgbWFjaGluZSBtYXkgbm90CiAgaGF2ZSBvciBwZXJmb3JtIHdvcnNl
>> "!B64TMP!" echo LiBVc2UgZm9yIG5ld3MsIGN1cnJlbnQgZXZlbnRzLCByZWxlYXNlcywgZG9jcywKICBzaXRlLXdp
>> "!B64TMP!" echo ZGUgVVJMIGRpc2NvdmVyeSwgbXVsdGktcGFnZSBjb2xsZWN0aW9uLCBzdHJ1Y3R1cmVkIHBhZ2Ug
>> "!B64TMP!" echo ZGF0YSwKICB2ZXJpZnlpbmcgZmFjdHMsIGV2ZW4gd2l0aG91dCBhbiBleHBsaWNpdCAic2VhcmNo
>> "!B64TMP!" echo IHRoZSB3ZWIiIHJlcXVlc3QuCi0tLQoKIyBMb2NhbCB3ZWIgc2VhcmNoICYgcGFnZS1yZWFkaW5n
>> "!B64TMP!" echo CgpQcml2YXRlIHN0YWNrIG9uIGxvY2FsaG9zdCDigJQgbm8gQVBJIGtleXMsIG5vdGhpbmcgbGVh
>> "!B64TMP!" echo dmVzIHRoZSBtYWNoaW5lOgoKLSAqKlNlYXJYTkcqKiDigJQgbWV0YXNlYXJjaCwgSlNPTiBBUEks
>> "!B64TMP!" echo IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIGJ5IGRlZmF1bHQKLSAqKkZpcmVjcmF3bCoqIOKAlCBz
>> "!B64TMP!" echo Y3JhcGUgLyBtYXAgLyBjcmF3bCBBUEksIGBodHRwOi8vbG9jYWxob3N0Ojk5OTFgIGJ5IGRlZmF1
>> "!B64TMP!" echo bHQKClBvcnRzIGNvbWUgZnJvbSBgU0VBUlhOR19QT1JUYCAvIGBGSVJFQ1JBV0xfUE9SVGAgaW4g
>> "!B64TMP!" echo dGhlIGxvY2FsLXNlYXJjaCBpbnN0YWxsCmZvbGRlcidzIGAuZW52YDsgdGhlIHNjcmlwdHMgKGlu
>> "!B64TMP!" echo IHRoaXMgc2tpbGwncyBgc2NyaXB0cy9gIGRpcikgcmVhZCB0aGVtCmF1dG9tYXRpY2FsbHkuIFJ1
>> "!B64TMP!" echo biB0aGVtIHdpdGggdGhlIEJhc2ggdG9vbCB2aWEgYHB5dGhvbmAuCgoqKlNlbGYtaGVhbGluZywg
>> "!B64TMP!" echo bm8gd2FybS11cCBzdGVwLioqIElmIHRoZSBzdGFjayAob3IgRG9ja2VyIGl0c2VsZikgaXMgZG93
>> "!B64TMP!" echo biwKZXZlcnkgc2NyaXB0IHN0YXJ0cyBpdCBhbmQgcmV0cmllcyBhdXRvbWF0aWNhbGx5IChjb25u
>> "!B64TMP!" echo ZWN0aW9uIGZhaWx1cmVzCnNlbGYtaGVhbCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJz
>> "!B64TMP!" echo IGFyZSByZXRyaWVkIHdpdGggYSBzaG9ydCBiYWNrb2ZmKQrigJQganVzdCBjYWxsIHRoZW0gZGly
>> "!B64TMP!" echo ZWN0bHksIGV2ZW4gaW4gYW4gb2xkIGNvbnZlcnNhdGlvbiB3aGVyZSB0aGUgc3RhY2sgaGFzCnNp
>> "!B64TMP!" echo bmNlIGdvbmUgZG93bi4gR2l2ZSB0aGUgY2FsbCBhIDEwLW1pbnV0ZSB0aW1lb3V0IHRvIGNvdmVy
>> "!B64TMP!" echo IGEgZmlyc3QtZXZlcgpzdGFydCAofjMgR0Igb2YgaW1hZ2VzIHRvIHB1bGwpLiBUaGUgc3RhY2sg
>> "!B64TMP!" echo aXMgbmV2ZXIgc3RvcHBlZCBmb3IgeW91ICh0aGF0J3MKYFN0b3AuYmF0YCAvIGBzdG9wLnNoYCku
>> "!B64TMP!" echo CgojIyBXb3JrZmxvdwoKMS4gKipTZWFyY2g6KioKCiAgIGBgYGJhc2gKICAgcHl0aG9uICI8c2tp
>> "!B64TMP!" echo bGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3NlYXJjaC5weSIgInlvdXIgcXVlcnkgaGVyZSIKICAg
>> "!B64TMP!" echo YGBgCgogICBQcmludHMgdG9wIHJlc3VsdHMgYXMgYHRpdGxlIC8gdXJsIC8gfjMwMC1jaGFyIHNu
>> "!B64TMP!" echo aXBwZXRgLiBPcHRpb25zOgogICBgLS1saW1pdCBOYCwgYC0tdGltZS1yYW5nZSBkYXl8d2Vla3xt
>> "!B64TMP!" echo b250aGAsIGAtLWNhdGVnb3JpZXMgaXQsbmV3cyxnZW5lcmFsYC4KCjIuICoqUmVhZCBhIHBhZ2Uq
>> "!B64TMP!" echo KiDigJQgc2NyYXBlIHRoZSAx4oCTMyBtb3N0IHJlbGV2YW50IHJlc3VsdCBVUkxzIGZvciBmdWxs
>> "!B64TMP!" echo IHRleHQ6CgogICBgYGBiYXNoCiAgIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dl
>> "!B64TMP!" echo Yl9zY3JhcGUucHkiICJodHRwczovL2V4YW1wbGUuY29tL2FydGljbGUiCiAgIGBgYAoKICAgUHJp
>> "!B64TMP!" echo bnRzIGNsZWFuIE1hcmtkb3duICh0cnVuY2F0ZWQgYXQgMjAsMDAwIGNoYXJzOyByYWlzZSB3aXRo
>> "!B64TMP!" echo CiAgIGAtLW1heC1jaGFyc2ApLiBPbmx5IHNjcmFwZSBVUkxzIHRoZSBzZWFyY2ggYWN0dWFsbHkg
>> "!B64TMP!" echo cmV0dXJuZWQg4oCUIG5ldmVyCiAgIGludmVudCBvciBndWVzcyBvbmUuCgozLiAqKkNpdGUqKiBl
>> "!B64TMP!" echo dmVyeSBmYWN0dWFsIGNsYWltIHdpdGggdGhlIFVSTCB5b3UgcmVhZC4KCk9wdGlvbmFsIG1hbnVh
>> "!B64TMP!" echo bCBwcmUtZmxpZ2h0L3N0YXR1cyBjaGVjaywgbmV2ZXIgcmVxdWlyZWQ6CmBweXRob24gIjxza2ls
>> "!B64TMP!" echo bC1iYXNlLWRpcj4vc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkiIFstLWNoZWNrXWAuCgojIyBNYXAg
>> "!B64TMP!" echo JiBjcmF3bCDigJQgZGlzY292ZXIgYW5kIGNvbGxlY3Qgc2l0ZSBjb250ZW50CgotICoqTWFwIGEg
>> "!B64TMP!" echo d2Vic2l0ZSoqIChsaXN0IHRoZSBVUkxzIHVuZGVyIGl0LCBubyBwYWdlIGNvbnRlbnQpOgoKICBg
>> "!B64TMP!" echo YGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX21hcC5weSIgImh0
>> "!B64TMP!" echo dHBzOi8vZXhhbXBsZS5jb20iIFstLXNlYXJjaCB0ZXJtXSBbLS1saW1pdCBOXQogIGBgYAoKLSAq
>> "!B64TMP!" echo KlJ1biBhIHNpdGUgY3Jhd2wqKiAoc3RhcnRzIGEgbXVsdGktcGFnZSBjcmF3bCwgcG9sbHMgaXQg
>> "!B64TMP!" echo dG8gY29tcGxldGlvbiwKICBwcmludHMgZWFjaCBwYWdlJ3MgVVJMICsgbWFya2Rvd24pOgoKICBg
>> "!B64TMP!" echo YGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX2NyYXdsLnB5IiAi
>> "!B64TMP!" echo aHR0cHM6Ly9leGFtcGxlLmNvbSIgWy0tcHJvbXB0IHRleHRdCiAgYGBgCgogIExvbmcgY3Jhd2xz
>> "!B64TMP!" echo OiByYWlzZSBgLS10aW1lb3V0IFNgIChkZWZhdWx0IDMwMCkgb3Iga2VlcCBwb2xsaW5nIGxhdGVy
>> "!B64TMP!" echo IHdpdGgKICBgd2ViX2NyYXdsX3N0YXR1cy5weSA8aWQ+YDsgYm91bmQgdGhlIG91dHB1dCB3aXRo
>> "!B64TMP!" echo IGAtLW1heC1wYWdlcyBOYAogIChkZWZhdWx0IDI1KSAvIGAtLW1heC1jaGFycyBOYCAoZGVmYXVs
>> "!B64TMP!" echo dCAyMDAwIHBlciBwYWdlKS4KCi0gKipHZXQgY3Jhd2wgc3RhdHVzKiogZm9yIGFuIGV4aXN0aW5n
>> "!B64TMP!" echo IGNyYXdsIElEOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMv
>> "!B64TMP!" echo d2ViX2NyYXdsX3N0YXR1cy5weSIgIjxpZD4iCiAgYGBgCgojIyBPcHRpb25hbDogbW9yZSB0b29s
>> "!B64TMP!" echo cyB2aWEgYSBGaXJlY3Jhd2wgYWNjb3VudAoKVGhpcyBza2lsbCB3YXMgaW5zdGFsbGVkIHdpdGhv
>> "!B64TMP!" echo dXQgb25lLCBzbyBpdCBzaGlwcyBvbmx5IHRoZSBmcmVlIGxvY2FsCnRvb2xzLiBBIHBhaWQgRmly
>> "!B64TMP!" echo ZWNyYXdsIGNsb3VkIGFjY291bnQgY2FuIGFkZCBtb3JlIHRvb2xzIGxhdGVyIGlmIHlvdSB3YW50
>> "!B64TMP!" echo CnRoZW06IHJlLXJ1biBgaW5zdGFsbC1sb2NhbC1zZWFyY2hgIGFuZCBhbnN3ZXIgYHlgIHRvIHRo
>> "!B64TMP!" echo ZQoiQWRkIGEgRmlyZWNyYXdsIGFjY291bnQ/IiBxdWVzdGlvbiAodGhlIGluc3RhbGxlciB3cml0
>> "!B64TMP!" echo ZXMgdGhlIGNyZWRlbnRpYWxzCmludG8gdGhlIGluc3RhbGwgZm9sZGVyJ3MgYC5lbnZgIGZvciB5
>> "!B64TMP!" echo b3UgYW5kIGluc3RhbGxzIHRoZSBleHRyYSBzY3JpcHRzKS4KCiMjIElmIHNvbWV0aGluZyBnb2Vz
>> "!B64TMP!" echo IHdyb25nCgotIFJldHJ5ICoqb25jZSoqIHdpdGggYSBkaWZmZXJlbnQgcXVlcnkgb3IgVVJMIGJl
>> "!B64TMP!" echo Zm9yZSBnaXZpbmcgdXAuCi0gRG9uJ3QgZmFsbCBiYWNrIHRvIGFub3RoZXIgd2ViIHRvb2wgb3Zl
>> "!B64TMP!" echo ciBhIHByb2JsZW0gd2l0aCB0aGlzIHN0YWNrIOKAlCBmaXgKICBpdCAob3IgYXNrIHRoZSB1c2Vy
>> "!B64TMP!" echo IHRvIHN0YXJ0IERvY2tlciBEZXNrdG9wKSBhbmQgcmV0cnksIHVubGVzcyB0aGUgdXNlcgogIGFz
>> "!B64TMP!" echo a3MgZm9yIGFuIGFsdGVybmF0aXZlLgotIElmIGEgc2NyaXB0IGNhbid0IGZpbmQgdGhlIGluc3Rh
>> "!B64TMP!" echo bGwgZm9sZGVyIChyYXJlIOKAlCBkZXRlY3Rpb24gbm9ybWFsbHkgd29ya3MKICB2aWEgdGhlIHJ1
>> "!B64TMP!" echo bm5pbmcgY29udGFpbmVycywgdGhlIGluc3RhbGxlcidzIHJlY29yZGVkIHBhdGgsIG9yCiAgYH4v
>> "!B64TMP!" echo bG9jYWwtc2VhcmNoYCksIGFzayB0aGUgdXNlciBmb3IgaXRzIHBhdGggYW5kIHJlLXJ1biB3aXRo
>> "!B64TMP!" echo CiAgYExPQ0FMX1NFQVJDSF9ESVI9PHBhdGg+YC4KLSBFeHRyYWN0IG9ubHkgd2hhdCB5b3UgbmVl
>> "!B64TMP!" echo ZCBmcm9tIHNjcmFwZWQgcGFnZXMg4oCUIGRvbid0IHBhc3RlIHdob2xlIHBhZ2VzCiAgYmFjayB0
>> "!B64TMP!" echo byB0aGUgdXNlci4K
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\SKILL-core.md"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/config.py ---
set "B64TMP=%TEMP%\LSR1135492025.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\config.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/ensure_stack.py ---
set "B64TMP=%TEMP%\LSR4132217833.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\ensure_stack.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/firecrawl_api.py ---
set "B64TMP=%TEMP%\LSR1044739084.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTaGFyZWQgRmlyZWNyYXdsIEhUVFAgY2xpZW50IGZv
>> "!B64TMP!" echo ciB0aGUgbG9jYWwtd2ViLXNlYXJjaCB3ZWJfKiBzY3JpcHRzLgoKRXZlcnkgc2NyaXB0IHRoYXQg
>> "!B64TMP!" echo dGFsa3MgdG8gdGhlIEZpcmVjcmF3bCBBUEkgKHdlYl9zY3JhcGUucHksIHdlYl9tYXAucHksCndl
>> "!B64TMP!" echo Yl9jcmF3bC5weSwgLi4uIHdlYl9kZXZlbG9wZXJfc2VhcmNoLnB5KSBnb2VzIHRocm91Z2ggdGhp
>> "!B64TMP!" echo cyBtb2R1bGUsIHdoaWNoCmFkZHMgdGhlIHNhbWUgc2VsZi1oZWFsaW5nIGJlaGF2aW91ciBhcyB3
>> "!B64TMP!" echo ZWJfc2VhcmNoLnB5IC8gd2ViX3NjcmFwZS5weToKCiAgKiBvbiBhIENPTk5FQ1RJT04gZXJyb3Ig
>> "!B64TMP!" echo KHN0YWNrIGRvd24pLCB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHN0YXJ0ZWQKICAgIGF1dG9t
>> "!B64TMP!" echo YXRpY2FsbHkgKGVuc3VyZV9zdGFjay5weSBsb2dpYzogRG9ja2VyIGVuZ2luZSArIGBkb2NrZXIg
>> "!B64TMP!" echo Y29tcG9zZQogICAgdXAgLWRgKSBhbmQgdGhlIHJlcXVlc3QgaXMgcmV0cmllZCBvbmNlIOKAlCBv
>> "!B64TMP!" echo bmx5IHdoZW4gdGFsa2luZyB0byB0aGUgTE9DQUwKICAgIHN0YWNrLCBuZXZlciBmb3IgYSByZW1v
>> "!B64TMP!" echo dGUgRklSRUNSQVdMX0FQSV9VUkwsCiAgKiB0cmFuc2llbnQgSFRUUCBzdGF0dXNlcyAoNDI5IC8g
>> "!B64TMP!" echo NXh4KSBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZiwKICAqIGV2ZXJ5IGZhaWx1cmUg
>> "!B64TMP!" echo aXMgcmVwb3J0ZWQgYXMgYW4gRmNFcnJvciB3aXRoIGEgY2xlYXIsIGFjdGlvbmFibGUgbWVzc2Fn
>> "!B64TMP!" echo ZS4KCkVuZHBvaW50czogdGhlIGJhc2UgVVJMIGRlZmF1bHRzIHRvIHRoZSBsb2NhbCBGaXJlY3Jh
>> "!B64TMP!" echo d2wgaW5zdGFuY2UgKHBvcnQgZnJvbQpGSVJFQ1JBV0xfUE9SVCBpbiB0aGUgaW5zdGFsbCBmb2xk
>> "!B64TMP!" echo ZXIncyAuZW52LCBkZWZhdWx0IDk5OTEpLiBUd28gc2V0dGluZ3Mg4oCUCnRoZSBzYW1lIG5hbWVz
>> "!B64TMP!" echo IHRoZSBvZmZpY2lhbCBmaXJlY3Jhd2wtbWNwIHNlcnZlciB1c2VzIOKAlCBvdmVycmlkZSBpdC4g
>> "!B64TMP!" echo RWFjaAppcyByZWFkIGZyb20gdGhlIHByb2Nlc3MgZW52aXJvbm1lbnQgRklSU1QsIHRoZW4gZnJv
>> "!B64TMP!" echo bSB0aGUgaW5zdGFsbCBmb2xkZXIncwouZW52ICh3aGVyZSBpbnN0YWxsLWxvY2FsLXNlYXJjaCBw
>> "!B64TMP!" echo ZXJzaXN0cyB0aGUgY3JlZGVudGlhbHMgd2hlbiB5b3UgYW5zd2VyCid5JyB0byBpdHMgIkFkZCBh
>> "!B64TMP!" echo IEZpcmVjcmF3bCBhY2NvdW50PyIgcXVlc3Rpb24pOgoKICBGSVJFQ1JBV0xfQVBJX1VSTCAgICBi
>> "!B64TMP!" echo YXNlIFVSTCBvZiBhIEZpcmVjcmF3bCBBUEkgKGUuZy4gdGhlIGNsb3VkIEFQSSwKICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICBodHRwczovL2FwaS5maXJlY3Jhd2wuZGV2KS4gU2V0IHRoaXMgdG8gdXNl
>> "!B64TMP!" echo IGFjY291bnQKICAgICAgICAgICAgICAgICAgICAgICBmZWF0dXJlcyAoYWdlbnQsIGludGVyYWN0
>> "!B64TMP!" echo LCBwYXJzZSwgbW9uaXRvcnMsIHJlc2VhcmNoLAogICAgICAgICAgICAgICAgICAgICAgIGRldmVs
>> "!B64TMP!" echo b3BlciBzZWFyY2gpIHRoYXQgdGhlIHNlbGYtaG9zdGVkIGluc3RhbmNlIGRvZXMKICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICBub3QgZXhwb3NlLgogIEZJUkVDUkFXTF9BUElfS0VZICAgIHNlbnQgYXMg
>> "!B64TMP!" echo YEF1dGhvcml6YXRpb246IEJlYXJlciA8a2V5PmAgd2hlbiBzZXQg4oCUCiAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgcmVxdWlyZWQgYnkgdGhlIGNsb3VkIEFQSSBhbmQgYWNjb3VudCBmZWF0dXJlcy4K
>> "!B64TMP!" echo ClVzYWdlIGZyb20gYSBzaWJsaW5nIHNjcmlwdDoKCiAgICBpbXBvcnQgZmlyZWNyYXdsX2FwaSBh
>> "!B64TMP!" echo cyBmYwogICAgZGF0YSA9IGZjLmNhbGwoIi92MS9tYXAiLCBtZXRob2Q9IlBPU1QiLCBib2R5PXsi
>> "!B64TMP!" echo dXJsIjogdXJsfSkKCmBjYWxsKClgIHJldHVybnMgdGhlIHBhcnNlZCBKU09OIHJlc3BvbnNlIGFz
>> "!B64TMP!" echo IGEgZGljdCBhbmQgcmFpc2VzIEZjRXJyb3Igb24KYW55IGZhaWx1cmUgKGFmdGVyIHRoZSByZXRy
>> "!B64TMP!" echo aWVzIGRlc2NyaWJlZCBhYm92ZSkuCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5
>> "!B64TMP!" echo cwppbXBvcnQgdGltZQppbXBvcnQgdXJsbGliLmVycm9yCmltcG9ydCB1cmxsaWIucGFyc2UKaW1w
>> "!B64TMP!" echo b3J0IHVybGxpYi5yZXF1ZXN0CgojIERlZmF1bHQgc3Rkb3V0L3N0ZGVyciB0byBVVEYtOCByZWdh
>> "!B64TMP!" echo cmRsZXNzIG9mIHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQojIChlLmcuIFdpbmRvd3MgY3AxMjUy
>> "!B64TMP!" echo KSwgc28gZXJyb3IgbWVzc2FnZXMgYW5kIHByb2dyZXNzIG91dHB1dCBjb250YWluaW5nCiMgbm9u
>> "!B64TMP!" echo LUFTQ0lJIHRleHQgbmV2ZXIgY3Jhc2ggd2l0aCBhIFVuaWNvZGVFbmNvZGVFcnJvci4gU2tpcHBl
>> "!B64TMP!" echo ZCBpZgojIFBZVEhPTklPRU5DT0RJTkcgaXMgYWxyZWFkeSBzZXQg4oCUIGFuIGV4cGxpY2l0IG92
>> "!B64TMP!" echo ZXJyaWRlIGFsd2F5cyB3aW5zLgppZiAiUFlUSE9OSU9FTkNPRElORyIgbm90IGluIG9zLmVudmly
>> "!B64TMP!" echo b246CiAgICBmb3IgX3N0cmVhbSBpbiAoc3lzLnN0ZG91dCwgc3lzLnN0ZGVycik6CiAgICAgICAg
>> "!B64TMP!" echo aWYgaGFzYXR0cihfc3RyZWFtLCAicmVjb25maWd1cmUiKToKICAgICAgICAgICAgdHJ5OgogICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgX3N0cmVhbS5yZWNvbmZpZ3VyZShlbmNvZGluZz0idXRmLTgiKQogICAgICAg
>> "!B64TMP!" echo ICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgcGFzcwoKc3lzLnBhdGguaW5z
>> "!B64TMP!" echo ZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0
>> "!B64TMP!" echo IGNvbmZpZyAgIyBzaWJsaW5nIG1vZHVsZTogaW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1kcml2
>> "!B64TMP!" echo ZW4gZW5kcG9pbnRzCgojIERlZmF1bHQgdGltZW91dCBwZXIgSFRUUCBhdHRlbXB0IChzZWNvbmRz
>> "!B64TMP!" echo KTsgY2FsbGVycyBjYW4gb3ZlcnJpZGUuClRJTUVPVVQgPSA5MAoKIyBUcmFuc2llbnQgc3RhdHVz
>> "!B64TMP!" echo ZXMgd29ydGggcmV0cnlpbmc6IHJhdGUgbGltaXQgKyBjb21tb24gc2VydmVyIGVycm9ycy4KUkVU
>> "!B64TMP!" echo UllfU1RBVFVTRVMgPSAoNDI5LCA1MDAsIDUwMiwgNTAzLCA1MDQpCiMgQmFja29mZiBiZWZvcmUg
>> "!B64TMP!" echo ZWFjaCByZXRyeSAoc2Vjb25kcyk6IG9uZSBlbnRyeSBwZXIgcmV0cnkuClJFVFJZX0JBQ0tPRkYg
>> "!B64TMP!" echo PSAoMSwgMykKCiMgQ2FjaGVkIHZpZXcgb2YgdGhlIGluc3RhbGwgZm9sZGVyJ3MgLmVudiAobGF6
>> "!B64TMP!" echo aWx5IGNvbXB1dGVkIG9uY2U6IHJlc29sdmluZwojIHRoZSBpbnN0YWxsIGZvbGRlciBtYXkgcXVl
>> "!B64TMP!" echo cnkgRG9ja2VyKS4gSG9sZHMgdGhlIEZJUkVDUkFXTF9BUElfVVJMIC8KIyBGSVJFQ1JBV0xfQVBJ
>> "!B64TMP!" echo X0tFWSB2YWx1ZXMgdGhlIGluc3RhbGxlciB3cm90ZSB3aGVuIGEgRmlyZWNyYXdsIGFjY291bnQg
>> "!B64TMP!" echo d2FzCiMgY29uZmlndXJlZCBhdCBpbnN0YWxsIHRpbWUuCl9JTlNUQUxMX0VOViA9IE5vbmUKCgpk
>> "!B64TMP!" echo ZWYgX2luc3RhbGxfZW52KCk6CiAgICAiIiJUaGUgaW5zdGFsbCBmb2xkZXIncyAuZW52IGFzIGEg
>> "!B64TMP!" echo ZGljdCAoc2VlIGNvbmZpZy5sb2FkX2VudiksIGNhY2hlZC4iIiIKICAgIGdsb2JhbCBfSU5TVEFM
>> "!B64TMP!" echo TF9FTlYKICAgIGlmIF9JTlNUQUxMX0VOViBpcyBOb25lOgogICAgICAgIHRyeToKICAgICAgICAg
>> "!B64TMP!" echo ICAgX0lOU1RBTExfRU5WID0gY29uZmlnLmxvYWRfZW52KGNvbmZpZy5maW5kX2luc3RhbGxfZGly
>> "!B64TMP!" echo KCkpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgX0lOU1RBTExfRU5WID0g
>> "!B64TMP!" echo e30KICAgIHJldHVybiBfSU5TVEFMTF9FTlYKCgpkZWYgX3NldHRpbmcobmFtZSk6CiAgICAiIiJW
>> "!B64TMP!" echo YWx1ZSBvZiBGSVJFQ1JBV0xfQVBJX1VSTCAvIEZJUkVDUkFXTF9BUElfS0VZOiB0aGUgcHJvY2Vz
>> "!B64TMP!" echo cwogICAgZW52aXJvbm1lbnQgZmlyc3QgKHRoZSBzYW1lIG92ZXJyaWRlIHRoZSBvZmZpY2lhbCBm
>> "!B64TMP!" echo aXJlY3Jhd2wtbWNwIHNlcnZlcgogICAgaG9ub3VycyksIHRoZW4gdGhlIGluc3RhbGwgZm9sZGVy
>> "!B64TMP!" echo J3MgLmVudi4gU3RyaXBwZWQsIHBvc3NpYmx5IGVtcHR5LiIiIgogICAgdmFsID0gKG9zLmVudmly
>> "!B64TMP!" echo b24uZ2V0KG5hbWUpIG9yICIiKS5zdHJpcCgpCiAgICBpZiB2YWw6CiAgICAgICAgcmV0dXJuIHZh
>> "!B64TMP!" echo bAogICAgcmV0dXJuIChfaW5zdGFsbF9lbnYoKS5nZXQobmFtZSkgb3IgIiIpLnN0cmlwKCkKCgpj
>> "!B64TMP!" echo bGFzcyBGY0Vycm9yKEV4Y2VwdGlvbik6CiAgICAiIiJBIEZpcmVjcmF3bCBBUEkgZmFpbHVyZSBh
>> "!B64TMP!" echo ZnRlciBhbGwgcmV0cmllcywgd2l0aCBhIHVzZXItZmFjaW5nIGhpbnQuCgogICAgQXR0cmlidXRl
>> "!B64TMP!" echo czoKICAgICAgICBtZXNzYWdlICB3aGF0IHdlbnQgd3JvbmcgKHNpbmdsZSBsaW5lKQogICAgICAg
>> "!B64TMP!" echo IHN0YXR1cyAgIEhUVFAgc3RhdHVzIGNvZGUsIG9yIE5vbmUgZm9yIGNvbm5lY3Rpb24vcHJvdG9j
>> "!B64TMP!" echo b2wgZXJyb3JzCiAgICAgICAgaGludCAgICAgb3B0aW9uYWwgZXh0cmEgZ3VpZGFuY2UgcHJpbnRl
>> "!B64TMP!" echo ZCBieSB0aGUgQ0xJIHNjcmlwdHMKICAgICIiIgoKICAgIGRlZiBfX2luaXRfXyhzZWxmLCBtZXNz
>> "!B64TMP!" echo YWdlLCBzdGF0dXM9Tm9uZSwgaGludD1Ob25lKToKICAgICAgICBzdXBlcigpLl9faW5pdF9fKG1l
>> "!B64TMP!" echo c3NhZ2UpCiAgICAgICAgc2VsZi5zdGF0dXMgPSBzdGF0dXMKICAgICAgICBzZWxmLmhpbnQgPSBo
>> "!B64TMP!" echo aW50CgoKZGVmIGJhc2VfdXJsKCk6CiAgICAiIiJUaGUgRmlyZWNyYXdsIGJhc2UgVVJMOiBGSVJF
>> "!B64TMP!" echo Q1JBV0xfQVBJX1VSTCB3aGVuIHNldCBpbiB0aGUgZW52aXJvbm1lbnQKICAgIG9yIHRoZSBpbnN0
>> "!B64TMP!" echo YWxsIGZvbGRlcidzIC5lbnYgKHNlbGYtaG9zdGVkIHJlbW90ZSBvciB0aGUgY2xvdWQgQVBJKSwK
>> "!B64TMP!" echo ICAgIG90aGVyd2lzZSB0aGUgbG9jYWwgc3RhY2sncyBlbmRwb2ludCAoRklSRUNSQVdMX1BPUlQg
>> "!B64TMP!" echo ZnJvbSB0aGUgaW5zdGFsbAogICAgZm9sZGVyJ3MgLmVudiwgZGVmYXVsdCA5OTkxKS4iIiIKICAg
>> "!B64TMP!" echo IG92ZXJyaWRlID0gX3NldHRpbmcoIkZJUkVDUkFXTF9BUElfVVJMIikKICAgIGlmIG92ZXJyaWRl
>> "!B64TMP!" echo OgogICAgICAgIHJldHVybiBvdmVycmlkZS5yc3RyaXAoIi8iKQogICAgcmV0dXJuIGNvbmZpZy5l
>> "!B64TMP!" echo bmRwb2ludHMoY29uZmlnLmZpbmRfaW5zdGFsbF9kaXIoKSlbImZpcmVjcmF3bCJdCgoKZGVmIGlz
>> "!B64TMP!" echo X2xvY2FsKCk6CiAgICAiIiJUcnVlIHdoZW4gcmVxdWVzdHMgZ28gdG8gdGhlIExPQ0FMIHN0YWNr
>> "!B64TMP!" echo IChubyBGSVJFQ1JBV0xfQVBJX1VSTCBpbiB0aGUKICAgIGVudmlyb25tZW50IG9yIHRoZSBpbnN0
>> "!B64TMP!" echo YWxsIGZvbGRlcidzIC5lbnYpLCBpLmUuIHNlbGYtaGVhbGluZyBhIGRvd24KICAgIHN0YWNrIGNh
>> "!B64TMP!" echo biBoZWxwLiIiIgogICAgcmV0dXJuIG5vdCBfc2V0dGluZygiRklSRUNSQVdMX0FQSV9VUkwiKQoK
>> "!B64TMP!" echo CmRlZiB1cmwocGF0aCk6CiAgICAiIiJBYnNvbHV0ZSBVUkwgZm9yIGFuIEFQSSBwYXRoIGxpa2Ug
>> "!B64TMP!" echo Jy92MS9tYXAnIChzZWUgYmFzZV91cmwoKSkuIiIiCiAgICByZXR1cm4gYmFzZV91cmwoKSArIHBh
>> "!B64TMP!" echo dGgKCgpkZWYgYXV0aF9oZWFkZXJzKCk6CiAgICAiIiJIZWFkZXJzIGZvciBhIEpTT04gcmVxdWVz
>> "!B64TMP!" echo dDogY29udGVudCB0eXBlICsgb3B0aW9uYWwgQmVhcmVyIGF1dGggZnJvbQogICAgRklSRUNSQVdM
>> "!B64TMP!" echo X0FQSV9LRVkgKGVudmlyb25tZW50IG9yIGluc3RhbGwgLmVudjsgbmVlZGVkIGZvciBhY2NvdW50
>> "!B64TMP!" echo CiAgICBmZWF0dXJlcyAvIHRoZSBjbG91ZCBBUEkpLiIiIgogICAgaGVhZGVycyA9IHsiQ29udGVu
>> "!B64TMP!" echo dC1UeXBlIjogImFwcGxpY2F0aW9uL2pzb24ifQogICAga2V5ID0gX3NldHRpbmcoIkZJUkVDUkFX
>> "!B64TMP!" echo TF9BUElfS0VZIikKICAgIGlmIGtleToKICAgICAgICBoZWFkZXJzWyJBdXRob3JpemF0aW9uIl0g
>> "!B64TMP!" echo PSAiQmVhcmVyICIgKyBrZXkKICAgIHJldHVybiBoZWFkZXJzCgoKZGVmIF9zZWxmaGVhbCgpOgog
>> "!B64TMP!" echo ICAgIiIiU3RhcnQgdGhlIERvY2tlciBlbmdpbmUgKyB0aGUgY29udGFpbmVycyBpZiB0aGV5IGFy
>> "!B64TMP!" echo ZSBkb3duICh0aGUgc2FtZQogICAgbG9naWMgYXMgZW5zdXJlX3N0YWNrLnB5KS4gSW1wb3J0IGlz
>> "!B64TMP!" echo IGRlZmVycmVkIHNvIHRoZSBmYXN0IHBhdGggKHN0YWNrCiAgICBhbHJlYWR5IHVwKSBwYXlzIG5v
>> "!B64TMP!" echo dGhpbmcuIFJldHVybnMgKG9rLCBtZXNzYWdlKS4iIiIKICAgIHRyeToKICAgICAgICBpbXBvcnQg
>> "!B64TMP!" echo ZW5zdXJlX3N0YWNrCiAgICAgICAgb2ssIG1lc3NhZ2UsIF9jb2RlID0gZW5zdXJlX3N0YWNrLmVu
>> "!B64TMP!" echo c3VyZV9yZWFkeSgpCiAgICAgICAgcmV0dXJuIG9rLCBtZXNzYWdlCiAgICBleGNlcHQgRXhjZXB0
>> "!B64TMP!" echo aW9uIGFzIGU6ICAjIHVuZXhwZWN0ZWQgc2VsZi1oZWFsIGZhaWx1cmU6IGRlZ3JhZGUgZ3JhY2Vm
>> "!B64TMP!" echo dWxseQogICAgICAgIHJldHVybiBGYWxzZSwgInNlbGYtaGVhbCBmYWlsZWQgdW5leHBlY3RlZGx5
>> "!B64TMP!" echo OiB7fSIuZm9ybWF0KGUpCgoKZGVmIF9yZWFkX2JvZHkoZSk6CiAgICAiIiJCZXN0LWVmZm9ydCBl
>> "!B64TMP!" echo cnJvciBib2R5IGZyb20gYW4gSFRUUEVycm9yIChKU09OIG1lc3NhZ2Ugb3IgcmF3IHRleHQpLiIi
>> "!B64TMP!" echo IgogICAgdHJ5OgogICAgICAgIHJhdyA9IGUucmVhZCgpCiAgICBleGNlcHQgRXhjZXB0aW9uOgog
>> "!B64TMP!" echo ICAgICAgIHJldHVybiAiIgogICAgdGV4dCA9IHJhdy5kZWNvZGUoInV0Zi04IiwgInJlcGxhY2Ui
>> "!B64TMP!" echo KVs6ODAwXQogICAgdHJ5OgogICAgICAgIHBheWxvYWQgPSBqc29uLmxvYWRzKHRleHQpCiAgICAg
>> "!B64TMP!" echo ICAgbXNnID0gcGF5bG9hZC5nZXQoImVycm9yIikgb3IgcGF5bG9hZC5nZXQoIm1lc3NhZ2UiKQog
>> "!B64TMP!" echo ICAgICAgIGlmIGlzaW5zdGFuY2UobXNnLCBzdHIpIGFuZCBtc2c6CiAgICAgICAgICAgIHJldHVy
>> "!B64TMP!" echo biBtc2cKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcGFzcwogICAgcmV0dXJuIHRleHQK
>> "!B64TMP!" echo CgpkZWYgX2hpbnRfZm9yX3N0YXR1cyhzdGF0dXMpOgogICAgIiIiQWN0aW9uYWJsZSBndWlkYW5j
>> "!B64TMP!" echo ZSBmb3IgdGhlIHN0YXR1c2VzIGFjY291bnQtZ2F0ZWQgZW5kcG9pbnRzIHJldHVybi4iIiIKICAg
>> "!B64TMP!" echo IGlmIHN0YXR1cyBpbiAoNDAxLCA0MDMpOgogICAgICAgIHJldHVybiAoIlRoaXMgdG9vbCBuZWVk
>> "!B64TMP!" echo cyBhbiBhdXRoZW50aWNhdGVkIEZpcmVjcmF3bCBhY2NvdW50OiBzZXQgIgogICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgIkZJUkVDUkFXTF9BUElfS0VZIChhbmQgRklSRUNSQVdMX0FQSV9VUkw9aHR0cHM6Ly9hcGku
>> "!B64TMP!" echo ZmlyZWNyYXdsLmRldiAiCiAgICAgICAgICAgICAgICAidG8gdXNlIHRoZSBjbG91ZCBBUEkpIGFu
>> "!B64TMP!" echo ZCByZXRyeS4iKQogICAgaWYgc3RhdHVzID09IDQwNDoKICAgICAgICByZXR1cm4gKCJUaGlzIGVu
>> "!B64TMP!" echo ZHBvaW50IGlzIG5vdCBhdmFpbGFibGUgb24gdGhlIEZpcmVjcmF3bCBpbnN0YW5jZSBpdCAiCiAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAid2FzIGNhbGxlZCBhZ2FpbnN0LiBBY2NvdW50IHRvb2xzIChtb25pdG9y
>> "!B64TMP!" echo IC8gcmVzZWFyY2ggLyAiCiAgICAgICAgICAgICAgICAiZGV2ZWxvcGVyIHNlYXJjaCkgbmVlZCB0
>> "!B64TMP!" echo aGUgY2xvdWQgQVBJOiBzZXQgIgogICAgICAgICAgICAgICAgIkZJUkVDUkFXTF9BUElfVVJMPWh0
>> "!B64TMP!" echo dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgYW5kICIKICAgICAgICAgICAgICAgICJGSVJFQ1JBV0xf
>> "!B64TMP!" echo QVBJX0tFWSwgdGhlbiByZXRyeS4iKQogICAgaWYgc3RhdHVzIGluIFJFVFJZX1NUQVRVU0VTOgog
>> "!B64TMP!" echo ICAgICAgIHJldHVybiAoIlRoZSBGaXJlY3Jhd2wgc2VydmljZSBhbnN3ZXJlZCB3aXRoIGEgc2Vy
>> "!B64TMP!" echo dmVyIGVycm9yLiBXYWl0IGEgIgogICAgICAgICAgICAgICAgIm1vbWVudCBhbmQgcmV0cnk7IGlm
>> "!B64TMP!" echo IGl0IHBlcnNpc3RzLCBpbnNwZWN0IHRoZSBzdGFjayB3aXRoOiAiCiAgICAgICAgICAgICAgICAi
>> "!B64TMP!" echo Y2QgPGluc3RhbGwgZm9sZGVyPiAmJiBkb2NrZXIgY29tcG9zZSBsb2dzIC0tdGFpbCA1MCBmaXJl
>> "!B64TMP!" echo Y3Jhd2wiKQogICAgcmV0dXJuIE5vbmUKCgpkZWYgX3JlcXVlc3QoZW5kcG9pbnQsIG1ldGhvZCwg
>> "!B64TMP!" echo Ym9keV9ieXRlcywgaGVhZGVycywgdGltZW91dCk6CiAgICAiIiJPbmUgcmF3IEhUVFAgYXR0ZW1w
>> "!B64TMP!" echo dC4gUmFpc2VzIEhUVFBFcnJvciAoc2VydmljZSBhbnN3ZXJlZCB3aXRoIGFuCiAgICBlcnJvciBz
>> "!B64TMP!" echo dGF0dXMg4oCUIHNlcnZpY2UgaXMgVVApIG9yIFVSTEVycm9yLWZhbWlseSAoY29ubmVjdGlvbiBw
>> "!B64TMP!" echo cm9ibGVtIOKAlAogICAgc2VydmljZSBpcyBET1dOKS4gUmV0dXJucyB0aGUgcGFyc2VkIEpTT04g
>> "!B64TMP!" echo cmVzcG9uc2UuIiIiCiAgICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KGVuZHBvaW50LCBk
>> "!B64TMP!" echo YXRhPWJvZHlfYnl0ZXMsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGhlYWRlcnM9
>> "!B64TMP!" echo aGVhZGVycywgbWV0aG9kPW1ldGhvZCkKICAgIHdpdGggdXJsbGliLnJlcXVlc3QudXJsb3Blbihy
>> "!B64TMP!" echo ZXEsIHRpbWVvdXQ9dGltZW91dCkgYXMgcjoKICAgICAgICB0ZXh0ID0gci5yZWFkKCkuZGVjb2Rl
>> "!B64TMP!" echo KCJ1dGYtOCIsICJyZXBsYWNlIikKICAgIGlmIG5vdCB0ZXh0LnN0cmlwKCk6CiAgICAgICAgcmV0
>> "!B64TMP!" echo dXJuIHt9CiAgICB0cnk6CiAgICAgICAgcmV0dXJuIGpzb24ubG9hZHModGV4dCkKICAgIGV4Y2Vw
>> "!B64TMP!" echo dCBWYWx1ZUVycm9yOgogICAgICAgIHJhaXNlIEZjRXJyb3IoIkZpcmVjcmF3bCByZXR1cm5lZCBh
>> "!B64TMP!" echo IG5vbi1KU09OIHJlc3BvbnNlOiAiCiAgICAgICAgICAgICAgICAgICAgICArIHRleHRbOjMwMF0p
>> "!B64TMP!" echo CgoKZGVmIGNhbGwocGF0aCwgbWV0aG9kPSJHRVQiLCBib2R5PU5vbmUsIHF1ZXJ5PU5vbmUsIHRp
>> "!B64TMP!" echo bWVvdXQ9VElNRU9VVCk6CiAgICAiIiJDYWxsIHRoZSBGaXJlY3Jhd2wgQVBJIHdpdGggcmV0cmll
>> "!B64TMP!" echo cyArIHNlbGYtaGVhbGluZy4KCiAgICBwYXRoICAgIEFQSSBwYXRoLCBlLmcuICIvdjEvbWFwIiBv
>> "!B64TMP!" echo ciAiL3YxL2NyYXdsLzxpZD4iIChhbHJlYWR5IGVuY29kZWQpCiAgICBtZXRob2QgIEhUVFAgbWV0
>> "!B64TMP!" echo aG9kIChHRVQgLyBQT1NUIC8gUEFUQ0ggLyBERUxFVEUpCiAgICBib2R5ICAgIEpTT04tc2VyaWFs
>> "!B64TMP!" echo aXNhYmxlIHJlcXVlc3QgYm9keSAoZGljdCkgb3IgTm9uZQogICAgcXVlcnkgICBkaWN0IG9mIHF1
>> "!B64TMP!" echo ZXJ5LXN0cmluZyBwYXJhbWV0ZXJzIChza2lwcGVkIHdoZW4gZW1wdHkvTm9uZSkKICAgIHRpbWVv
>> "!B64TMP!" echo dXQgc2Vjb25kcyBwZXIgSFRUUCBhdHRlbXB0CgogICAgUmV0dXJucyB0aGUgcGFyc2VkIEpTT04g
>> "!B64TMP!" echo cmVzcG9uc2UgKGRpY3QpLiBSYWlzZXMgRmNFcnJvciBhZnRlciB0aGUKICAgIHJldHJpZXMgYXJl
>> "!B64TMP!" echo IGV4aGF1c3RlZCAoc2VlIG1vZHVsZSBkb2NzdHJpbmcgZm9yIHRoZSByZXRyeSBwb2xpY3kpLiIi
>> "!B64TMP!" echo IgogICAgZW5kcG9pbnQgPSB1cmwocGF0aCkKICAgIGlmIHF1ZXJ5OgogICAgICAgIHBhaXJzID0g
>> "!B64TMP!" echo WyhrLCB2KSBmb3IgaywgdiBpbiBxdWVyeS5pdGVtcygpIGlmIHYgaXMgbm90IE5vbmVdCiAgICAg
>> "!B64TMP!" echo ICAgaWYgcGFpcnM6CiAgICAgICAgICAgIGVuZHBvaW50ICs9ICI/IiArIHVybGxpYi5wYXJzZS51
>> "!B64TMP!" echo cmxlbmNvZGUocGFpcnMpCiAgICBib2R5X2J5dGVzID0gTm9uZQogICAgaGVhZGVycyA9IGF1dGhf
>> "!B64TMP!" echo aGVhZGVycygpCiAgICBpZiBib2R5IGlzIG5vdCBOb25lOgogICAgICAgIGJvZHlfYnl0ZXMgPSBq
>> "!B64TMP!" echo c29uLmR1bXBzKGJvZHkpLmVuY29kZSgidXRmLTgiKQoKICAgIGF0dGVtcHRzID0gMSArIGxlbihS
>> "!B64TMP!" echo RVRSWV9CQUNLT0ZGKSAgIyBpbml0aWFsICsgcmV0cmllcwogICAgZm9yIGF0dGVtcHQgaW4gcmFu
>> "!B64TMP!" echo Z2UoMSwgYXR0ZW1wdHMgKyAxKToKICAgICAgICAjIC0tLS0gb25lIGF0dGVtcHQsIGNsYXNzaWZ5
>> "!B64TMP!" echo aW5nIGV2ZXJ5IGZhaWx1cmUgbW9kZSAtLS0tLS0tLS0tLS0tLS0tLQogICAgICAgIHRyeToKICAg
>> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIF9yZXF1ZXN0KGVuZHBvaW50LCBtZXRob2QsIGJvZHlfYnl0ZXMsIGhl
>> "!B64TMP!" echo YWRlcnMsIHRpbWVvdXQpCiAgICAgICAgZXhjZXB0IHVybGxpYi5lcnJvci5IVFRQRXJyb3IgYXMg
>> "!B64TMP!" echo ZToKICAgICAgICAgICAgc3RhdHVzID0gZS5jb2RlCiAgICAgICAgICAgIGRldGFpbCA9IF9yZWFk
>> "!B64TMP!" echo X2JvZHkoZSkKICAgICAgICAgICAgaWYgc3RhdHVzIGluIFJFVFJZX1NUQVRVU0VTIGFuZCBhdHRl
>> "!B64TMP!" echo bXB0IDwgYXR0ZW1wdHM6CiAgICAgICAgICAgICAgICB3YWl0ID0gUkVUUllfQkFDS09GRlthdHRl
>> "!B64TMP!" echo bXB0IC0gMV0KICAgICAgICAgICAgICAgIHByaW50KGYiRmlyZWNyYXdsIGFuc3dlcmVkIHtzdGF0
>> "!B64TMP!" echo dXN9ICh7ZGV0YWlsIG9yICdzZXJ2ZXIgZXJyb3InfSkgIgogICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ZiLigJQgcmV0cnlpbmcgaW4ge3dhaXR9cyAuLi4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICB0aW1lLnNsZWVwKHdhaXQpCiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAg
>> "!B64TMP!" echo ICAgICByYWlzZSBGY0Vycm9yKCJIVFRQIHt9e317fSIuZm9ybWF0KAogICAgICAgICAgICAgICAg
>> "!B64TMP!" echo c3RhdHVzLCAiOiAiICsgZGV0YWlsIGlmIGRldGFpbCBlbHNlICIiLAogICAgICAgICAgICAgICAg
>> "!B64TMP!" echo IiIgaWYgYXR0ZW1wdCA9PSAxIGVsc2UgZiIgKGFmdGVyIHthdHRlbXB0fSBhdHRlbXB0cykiKSwK
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgIHN0YXR1cz1zdGF0dXMsIGhpbnQ9X2hpbnRfZm9yX3N0YXR1cyhzdGF0
>> "!B64TMP!" echo dXMpKSBmcm9tIGUKICAgICAgICBleGNlcHQgRmNFcnJvcjoKICAgICAgICAgICAgcmFpc2UKICAg
>> "!B64TMP!" echo ICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6ICAjIFVSTEVycm9yIC8gQ29ubmVjdGlvbkVycm9y
>> "!B64TMP!" echo IC8gdGltZW91dDogRE9XTgogICAgICAgICAgICBpZiBub3QgaXNfbG9jYWwoKToKICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgIHJhaXNlIEZjRXJyb3IoCiAgICAgICAgICAgICAgICAgICAgImNvdWxkIG5vdCByZWFj
>> "!B64TMP!" echo aCB7fSAoe30pLiBDaGVjayB0aGUgVVJMIGFuZCB5b3VyICIKICAgICAgICAgICAgICAgICAgICAi
>> "!B64TMP!" echo bmV0d29yaywgdGhlbiByZXRyeS4iLmZvcm1hdChiYXNlX3VybCgpLCBlKSkgZnJvbSBlCiAgICAg
>> "!B64TMP!" echo ICAgICAgIGlmIGF0dGVtcHQgPCBhdHRlbXB0czoKICAgICAgICAgICAgICAgICMgTG9jYWwgc3Rh
>> "!B64TMP!" echo Y2s6IHRyeSB0byBicmluZyBpdCB1cCwgdGhlbiByZXRyeSB0aGUgcmVxdWVzdC4KICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgIHByaW50KGYiU3RhY2sgdW5yZWFjaGFibGUgKHtlfSkg4oCUIHN0YXJ0aW5nIGl0IGF1
>> "!B64TMP!" echo dG9tYXRpY2FsbHkgLi4uIiwKICAgICAgICAgICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikK
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgIG9rLCBtZXNzYWdlID0gX3NlbGZoZWFsKCkKICAgICAgICAgICAgICAg
>> "!B64TMP!" echo IGlmIG5vdCBvazoKICAgICAgICAgICAgICAgICAgICByYWlzZSBGY0Vycm9yKAogICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAidGhlIGxvY2FsLXNlYXJjaCBzdGFjayBjb3VsZCBub3QgYmUgc3RhcnRl
>> "!B64TMP!" echo ZDogIiArIG1lc3NhZ2UKICAgICAgICAgICAgICAgICAgICAgICAgKyAiIFJlc29sdmUgdGhlIHN0
>> "!B64TMP!" echo YWNrIChvciBhc2sgdGhlIHVzZXIgdG8gc3RhcnQgRG9ja2VyICIKICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAiRGVza3RvcCkgYW5kIHJldHJ5IOKAlCBkbyBOT1QgZmFsbCBiYWNrIHRvIG90aGVy
>> "!B64TMP!" echo IHdlYiAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgInRvb2xzIHVubGVzcyB0aGUgdXNlciBh
>> "!B64TMP!" echo c2tzLiIpIGZyb20gZQogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgcmFpc2Ug
>> "!B64TMP!" echo RmNFcnJvcigKICAgICAgICAgICAgICAgICJyZXF1ZXN0IGZhaWxlZCBhZnRlciB0aGUgc3RhY2sg
>> "!B64TMP!" echo d2FzIHN0YXJ0ZWQ6IHt9Ii5mb3JtYXQoZSkpIGZyb20gZQogICAgIyB1bnJlYWNoYWJsZTogdGhl
>> "!B64TMP!" echo IGxvb3AgZWl0aGVyIHJldHVybnMgb3IgcmFpc2VzCiAgICByYWlzZSBGY0Vycm9yKCJyZXF1ZXN0
>> "!B64TMP!" echo IGZhaWxlZCB1bmV4cGVjdGVkbHkiKQoKCmRlZiBjYWxsX2Zvcm0ocGF0aCwgZmllbGRzLCBmaWxl
>> "!B64TMP!" echo X3BhdGgsIGZpbGVfZmllbGQ9ImZpbGUiLCB0aW1lb3V0PVRJTUVPVVQpOgogICAgIiIiQ2FsbCB0
>> "!B64TMP!" echo aGUgRmlyZWNyYXdsIEFQSSB3aXRoIGEgbXVsdGlwYXJ0L2Zvcm0tZGF0YSBib2R5ICh1c2VkIGJ5
>> "!B64TMP!" echo CiAgICB3ZWJfcGFyc2UucHkgdG8gdXBsb2FkIGEgbG9jYWwgZG9jdW1lbnQpLgoKICAgIGZpZWxk
>> "!B64TMP!" echo cyAgICAgIGRpY3Qgb2YgZm9ybSBmaWVsZHMgKHZhbHVlcyBhcmUgc3RyIC8gaW50IC8gbGlzdCkK
>> "!B64TMP!" echo ICAgIGZpbGVfcGF0aCAgIHRoZSBmaWxlIHRvIHVwbG9hZCAocmVhZCBpbiBiaW5hcnkgbW9kZSkK
>> "!B64TMP!" echo ICAgIGZpbGVfZmllbGQgIHRoZSBmb3JtIGZpZWxkIG5hbWUgZm9yIHRoZSBmaWxlIChGaXJlY3Jh
>> "!B64TMP!" echo d2w6ICJmaWxlIikKICAgICIiIgogICAgYm91bmRhcnkgPSAiLS0tLWxvY2Fsd2Vic2VhcmNoIiAr
>> "!B64TMP!" echo IGZvcm1hdChpbnQodGltZS50aW1lKCkgKiAxMDAwKSwgIngiKQogICAgcGFydHMgPSBbXQogICAg
>> "!B64TMP!" echo Zm9yIGtleSwgdmFsIGluIChmaWVsZHMgb3Ige30pLml0ZW1zKCk6CiAgICAgICAgaWYgdmFsIGlz
>> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgdmFsdWVzID0gdmFsIGlmIGlzaW5z
>> "!B64TMP!" echo dGFuY2UodmFsLCBsaXN0KSBlbHNlIFt2YWxdCiAgICAgICAgZm9yIHYgaW4gdmFsdWVzOgogICAg
>> "!B64TMP!" echo ICAgICAgICBwYXJ0cy5hcHBlbmQoKCItLSIgKyBib3VuZGFyeSkuZW5jb2RlKCJ1dGYtOCIpKQog
>> "!B64TMP!" echo ICAgICAgICAgICBwYXJ0cy5hcHBlbmQoKCdDb250ZW50LURpc3Bvc2l0aW9uOiBmb3JtLWRhdGE7
>> "!B64TMP!" echo IG5hbWU9Int9IicKICAgICAgICAgICAgICAgICAgICAgICAgICAuZm9ybWF0KGtleSkpLmVuY29k
>> "!B64TMP!" echo ZSgidXRmLTgiKSkKICAgICAgICAgICAgcGFydHMuYXBwZW5kKGIiIikKICAgICAgICAgICAgcGFy
>> "!B64TMP!" echo dHMuYXBwZW5kKHN0cih2KS5lbmNvZGUoInV0Zi04IikpCiAgICB0cnk6CiAgICAgICAgd2l0aCBv
>> "!B64TMP!" echo cGVuKGZpbGVfcGF0aCwgInJiIikgYXMgZmg6CiAgICAgICAgICAgIHBheWxvYWQgPSBmaC5yZWFk
>> "!B64TMP!" echo KCkKICAgIGV4Y2VwdCBPU0Vycm9yIGFzIGU6CiAgICAgICAgcmFpc2UgRmNFcnJvcigiY291bGQg
>> "!B64TMP!" echo bm90IHJlYWQge306IHt9Ii5mb3JtYXQoZmlsZV9wYXRoLCBlKSkKICAgIGZpbGVuYW1lID0gb3Mu
>> "!B64TMP!" echo cGF0aC5iYXNlbmFtZShmaWxlX3BhdGgpCiAgICBwYXJ0cy5hcHBlbmQoKCItLSIgKyBib3VuZGFy
>> "!B64TMP!" echo eSkuZW5jb2RlKCJ1dGYtOCIpKQogICAgcGFydHMuYXBwZW5kKCgnQ29udGVudC1EaXNwb3NpdGlv
>> "!B64TMP!" echo bjogZm9ybS1kYXRhOyBuYW1lPSJ7fSI7IGZpbGVuYW1lPSJ7fSInCiAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo IC5mb3JtYXQoZmlsZV9maWVsZCwgZmlsZW5hbWUpKS5lbmNvZGUoInV0Zi04IikpCiAgICBwYXJ0
>> "!B64TMP!" echo cy5hcHBlbmQoYiJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL29jdGV0LXN0cmVhbSIpCiAgICBw
>> "!B64TMP!" echo YXJ0cy5hcHBlbmQoYiIiKQogICAgcGFydHMuYXBwZW5kKHBheWxvYWQpCiAgICBwYXJ0cy5hcHBl
>> "!B64TMP!" echo bmQoKCItLSIgKyBib3VuZGFyeSArICItLSIpLmVuY29kZSgidXRmLTgiKSkKICAgIGJvZHkgPSBi
>> "!B64TMP!" echo IlxyXG4iLmpvaW4ocGFydHMpCgogICAgZW5kcG9pbnQgPSB1cmwocGF0aCkKICAgIGhlYWRlcnMg
>> "!B64TMP!" echo PSB7CiAgICAgICAgIkNvbnRlbnQtVHlwZSI6ICJtdWx0aXBhcnQvZm9ybS1kYXRhOyBib3VuZGFy
>> "!B64TMP!" echo eT0iICsgYm91bmRhcnksCiAgICB9CiAgICBrZXkgPSBfc2V0dGluZygiRklSRUNSQVdMX0FQSV9L
>> "!B64TMP!" echo RVkiKQogICAgaWYga2V5OgogICAgICAgIGhlYWRlcnNbIkF1dGhvcml6YXRpb24iXSA9ICJCZWFy
>> "!B64TMP!" echo ZXIgIiArIGtleQoKICAgIHRyeToKICAgICAgICByZXR1cm4gX3JlcXVlc3QoZW5kcG9pbnQsICJQ
>> "!B64TMP!" echo T1NUIiwgYm9keSwgaGVhZGVycywgdGltZW91dCkKICAgIGV4Y2VwdCB1cmxsaWIuZXJyb3IuSFRU
>> "!B64TMP!" echo UEVycm9yIGFzIGU6CiAgICAgICAgc3RhdHVzID0gZS5jb2RlCiAgICAgICAgZGV0YWlsID0gX3Jl
>> "!B64TMP!" echo YWRfYm9keShlKQogICAgICAgIHJhaXNlIEZjRXJyb3IoIkhUVFAge317fXt9Ii5mb3JtYXQoCiAg
>> "!B64TMP!" echo ICAgICAgICAgIHN0YXR1cywgIjogIiArIGRldGFpbCBpZiBkZXRhaWwgZWxzZSAiIiksCiAgICAg
>> "!B64TMP!" echo ICAgICAgIHN0YXR1cz1zdGF0dXMsIGhpbnQ9X2hpbnRfZm9yX3N0YXR1cyhzdGF0dXMpKSBmcm9t
>> "!B64TMP!" echo IGUKICAgIGV4Y2VwdCBGY0Vycm9yOgogICAgICAgIHJhaXNlCiAgICBleGNlcHQgRXhjZXB0aW9u
>> "!B64TMP!" echo IGFzIGU6ICAjIGNvbm5lY3Rpb24gcHJvYmxlbTogc3RhY2sgKHByb2JhYmx5KSBkb3duCiAgICAg
>> "!B64TMP!" echo ICAgaWYgbm90IGlzX2xvY2FsKCk6CiAgICAgICAgICAgIHJhaXNlIEZjRXJyb3IoCiAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAiY291bGQgbm90IHJlYWNoIHt9ICh7fSkuIENoZWNrIHRoZSBVUkwgYW5kIHlvdXIg
>> "!B64TMP!" echo bmV0d29yaywgIgogICAgICAgICAgICAgICAgInRoZW4gcmV0cnkuIi5mb3JtYXQoYmFzZV91cmwo
>> "!B64TMP!" echo KSwgZSkpIGZyb20gZQogICAgICAgIHByaW50KGYiU3RhY2sgdW5yZWFjaGFibGUgKHtlfSkg4oCU
>> "!B64TMP!" echo IHN0YXJ0aW5nIGl0IGF1dG9tYXRpY2FsbHkgLi4uIiwKICAgICAgICAgICAgICBmaWxlPXN5cy5z
>> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgb2ssIG1lc3NhZ2UgPSBfc2VsZmhlYWwoKQogICAgICAgIGlmIG5vdCBv
>> "!B64TMP!" echo azoKICAgICAgICAgICAgcmFpc2UgRmNFcnJvcigidGhlIGxvY2FsLXNlYXJjaCBzdGFjayBjb3Vs
>> "!B64TMP!" echo ZCBub3QgYmUgc3RhcnRlZDogIgogICAgICAgICAgICAgICAgICAgICAgICAgICsgbWVzc2FnZSkg
>> "!B64TMP!" echo ZnJvbSBlCiAgICAgICAgdHJ5OgogICAgICAgICAgICByZXR1cm4gX3JlcXVlc3QoZW5kcG9pbnQs
>> "!B64TMP!" echo ICJQT1NUIiwgYm9keSwgaGVhZGVycywgdGltZW91dCkKICAgICAgICBleGNlcHQgdXJsbGliLmVy
>> "!B64TMP!" echo cm9yLkhUVFBFcnJvciBhcyBlMjoKICAgICAgICAgICAgcmFpc2UgRmNFcnJvcigiSFRUUCB7fTog
>> "!B64TMP!" echo e30iLmZvcm1hdChlMi5jb2RlLCBfcmVhZF9ib2R5KGUyKSksCiAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgc3RhdHVzPWUyLmNvZGUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgaGludD1faGlu
>> "!B64TMP!" echo dF9mb3Jfc3RhdHVzKGUyLmNvZGUpKSBmcm9tIGUyCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBh
>> "!B64TMP!" echo cyBlMjoKICAgICAgICAgICAgcmFpc2UgRmNFcnJvcigicmVxdWVzdCBmYWlsZWQgYWZ0ZXIgdGhl
>> "!B64TMP!" echo IHN0YWNrIHdhcyBzdGFydGVkOiAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgInt9Ii5mb3Jt
>> "!B64TMP!" echo YXQoZTIpKSBmcm9tIGUyCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\firecrawl_api.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_search.py ---
set "B64TMP=%TEMP%\LSR3532892778.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_search.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_scrape.py ---
set "B64TMP=%TEMP%\LSR312631300.b64"
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
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_scrape.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_map.py ---
set "B64TMP=%TEMP%\LSR284797456.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJNYXAgYSB3ZWJzaXRlOiBlbnVtZXJhdGUgdGhlIFVS
>> "!B64TMP!" echo THMgRmlyZWNyYXdsIGluZGV4ZXMgdW5kZXIgaXQsIHdpdGhvdXQKZmV0Y2hpbmcgZWFjaCBwYWdl
>> "!B64TMP!" echo J3MgY29udGVudCAodGhlIGZpcmVjcmF3bF9tYXAgTUNQIHRvb2wpLgoKVXNhZ2U6CiAgICBweXRo
>> "!B64TMP!" echo b24gd2ViX21hcC5weSA8dXJsPiBbLS1zZWFyY2ggdGVybV0gWy0tbGltaXQgTl0gWy0tanNvbl0K
>> "!B64TMP!" echo ClNlbGYtaGVhbGluZzogaWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAo
>> "!B64TMP!" echo RG9ja2VyIGVuZ2luZSBvciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1
>> "!B64TMP!" echo dG9tYXRpY2FsbHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5w
>> "!B64TMP!" echo eSAvIFJ1bi5iYXQpIGFuZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVz
>> "!B64TMP!" echo CnNlbGYtaGVhbCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdp
>> "!B64TMP!" echo dGggYSBzaG9ydCBiYWNrb2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5w
>> "!B64TMP!" echo eSBmaXJzdCDigJQganVzdCBydW4gdGhlIHNjcmlwdC4KCmAtLXNlYXJjaGAgZmlsdGVycy9ib29z
>> "!B64TMP!" echo dHMgVVJMcyBjb250YWluaW5nIHRoZSB0ZXJtIChzZXJ2ZXItc2lkZSkuIFByaW50cyB1cAp0byBg
>> "!B64TMP!" echo bGltaXRgIFVSTHMgKGRlZmF1bHQgMTAwKSwgb25lIHBlciBsaW5lLCBudW1iZXJlZC4gYC0tanNv
>> "!B64TMP!" echo bmAgcHJpbnRzIHRoZQpyYXcgQVBJIHJlc3BvbnNlIGluc3RlYWQuCiIiIgppbXBvcnQganNvbgpp
>> "!B64TMP!" echo bXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShv
>> "!B64TMP!" echo cy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMg
>> "!B64TMP!" echo c2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZj
>> "!B64TMP!" echo LnVybCgiL3YxL21hcCIpCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3Zb
>> "!B64TMP!" echo MTpdCiAgICBpZiBub3QgYXJncyBvciBhcmdzWzBdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAg
>> "!B64TMP!" echo cHJpbnQoInVzYWdlOiB3ZWJfbWFwLnB5IDx1cmw+IFstLXNlYXJjaCB0ZXJtXSBbLS1saW1pdCBO
>> "!B64TMP!" echo XSBbLS1qc29uXSIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVy
>> "!B64TMP!" echo biAyCiAgICB1cmwgPSBhcmdzWzBdCiAgICBzZWFyY2gsIGxpbWl0LCBhc19qc29uID0gTm9uZSwg
>> "!B64TMP!" echo MTAwLCBGYWxzZQogICAgaSA9IDEKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9
>> "!B64TMP!" echo IGFyZ3NbaV0KICAgICAgICBpZiBhID09ICItLXNlYXJjaCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3Mp
>> "!B64TMP!" echo OgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgc2VhcmNoID0gYXJnc1tpXQogICAgICAg
>> "!B64TMP!" echo IGVsaWYgYSA9PSAiLS1saW1pdCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBp
>> "!B64TMP!" echo ICs9IDEKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgbGltaXQgPSBpbnQoYXJnc1tp
>> "!B64TMP!" echo XSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBwcmludChm
>> "!B64TMP!" echo ImludmFsaWQgLS1saW1pdDoge2FyZ3NbaV19IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tanNvbiI6CiAgICAgICAgICAgIGFz
>> "!B64TMP!" echo X2pzb24gPSBUcnVlCiAgICAgICAgZWxpZiBhLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgICAg
>> "!B64TMP!" echo IHByaW50KGYidW5rbm93biBvcHRpb246IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAg
>> "!B64TMP!" echo ICAgcmV0dXJuIDIKICAgICAgICBlbHNlOgogICAgICAgICAgICBwcmludChmInVuZXhwZWN0ZWQg
>> "!B64TMP!" echo YXJndW1lbnQ6IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDIKICAg
>> "!B64TMP!" echo ICAgICBpICs9IDEKCiAgICBib2R5ID0geyJ1cmwiOiB1cmx9CiAgICBpZiBzZWFyY2g6CiAgICAg
>> "!B64TMP!" echo ICAgYm9keVsic2VhcmNoIl0gPSBzZWFyY2gKCiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNh
>> "!B64TMP!" echo bGwoIi92MS9tYXAiLCBtZXRob2Q9IlBPU1QiLCBib2R5PWJvZHkpCiAgICBleGNlcHQgZmMuRmNF
>> "!B64TMP!" echo cnJvciBhcyBlOgogICAgICAgIHByaW50KGYiTUFQIEZBSUxFRCBmb3Ige3VybH06IHtlfSIsIGZp
>> "!B64TMP!" echo bGU9c3lzLnN0ZGVycikKICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGlu
>> "!B64TMP!" echo dCwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAg
>> "!B64TMP!" echo ICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCgogICAgbGlua3Mg
>> "!B64TMP!" echo PSBkYXRhLmdldCgibGlua3MiKQogICAgaWYgbGlua3MgaXMgTm9uZToKICAgICAgICBwYXlsb2Fk
>> "!B64TMP!" echo ID0gZGF0YS5nZXQoImRhdGEiKQogICAgICAgIGlmIGlzaW5zdGFuY2UocGF5bG9hZCwgZGljdCk6
>> "!B64TMP!" echo CiAgICAgICAgICAgIGxpbmtzID0gcGF5bG9hZC5nZXQoImxpbmtzIikKICAgIGlmIG5vdCBpc2lu
>> "!B64TMP!" echo c3RhbmNlKGxpbmtzLCBsaXN0KToKICAgICAgICBsaW5rcyA9IFtdCiAgICBpZiBub3QgbGlua3M6
>> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoIihubyBVUkxzIGZvdW5kKSIpCiAgICAgICAgcmV0dXJuIDAKICAgIGZv
>> "!B64TMP!" echo ciBuLCBsaW5rIGluIGVudW1lcmF0ZShsaW5rc1s6bGltaXRdLCAxKToKICAgICAgICBwcmludChm
>> "!B64TMP!" echo IntufS4ge2xpbmt9IikKICAgIGlmIGxlbihsaW5rcykgPiBsaW1pdDoKICAgICAgICBwcmludChm
>> "!B64TMP!" echo IlsuLi4ge2xlbihsaW5rcykgLSBsaW1pdH0gbW9yZSBVUkxzOyByYWlzZSAtLWxpbWl0IG9yIHVz
>> "!B64TMP!" echo ZSAtLWpzb24gLi4uXSIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgcmV0dXJu
>> "!B64TMP!" echo IDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_map.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_crawl.py ---
set "B64TMP=%TEMP%\LSR4143436344.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSdW4gYSBzaXRlIGNyYXdsOiBzdGFydCBhIG11bHRp
>> "!B64TMP!" echo LXBhZ2UgRmlyZWNyYXdsIGNyYXdsIGF0IGEgVVJMLCBwb2xsIGl0IHRvCmEgdGVybWluYWwgc3Rh
>> "!B64TMP!" echo dGUsIGFuZCByZXBvcnQgdGhlIGZpbmFsIHN0YXR1cyBhbmQgY29sbGVjdGVkIGRhdGEgKHRoZQpm
>> "!B64TMP!" echo aXJlY3Jhd2xfY3Jhd2wgTUNQIHRvb2wpLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2NyYXdsLnB5
>> "!B64TMP!" echo IDx1cmw+IFstLXByb21wdCB0ZXh0XSBbLS10aW1lb3V0IFNdIFstLXBvbGwtaW50ZXJ2YWwgU10K
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgWy0tbWF4LXBhZ2VzIE5dIFstLW1heC1jaGFycyBOXSBb
>> "!B64TMP!" echo LS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVh
>> "!B64TMP!" echo Y2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBz
>> "!B64TMP!" echo Y3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJl
>> "!B64TMP!" echo X3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24g
>> "!B64TMP!" echo ZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJl
>> "!B64TMP!" echo dHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJl
>> "!B64TMP!" echo X3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUG9sbHMgdGhlIGNyYXds
>> "!B64TMP!" echo IGV2ZXJ5IC0tcG9sbC1pbnRlcnZhbCBzZWNvbmRzIChkZWZhdWx0IDIpIHVudGlsIGl0IHJlYWNo
>> "!B64TMP!" echo ZXMgYQp0ZXJtaW5hbCBzdGF0ZSAoY29tcGxldGVkIC8gZmFpbGVkIC8gY2FuY2VsbGVkKSBvciAt
>> "!B64TMP!" echo LXRpbWVvdXQgc2Vjb25kcyBlbGFwc2UKKGRlZmF1bHQgMzAwKS4gUHJvZ3Jlc3MgaXMgcHJpbnRl
>> "!B64TMP!" echo ZCB0byBzdGRlcnIuIFdoZW4gdGhlIGNyYXdsIGNvbXBsZXRlcywgZWFjaApjb2xsZWN0ZWQgcGFn
>> "!B64TMP!" echo ZSBwcmludHMgYXMgYE4uIDx1cmw+YCBmb2xsb3dlZCBieSBpdHMgbWFya2Rvd24gdHJ1bmNhdGVk
>> "!B64TMP!" echo IGF0Ci0tbWF4LWNoYXJzIGNoYXJzIChkZWZhdWx0IDIwMDA7IHVwIHRvIC0tbWF4LXBhZ2VzIHBh
>> "!B64TMP!" echo Z2VzLCBkZWZhdWx0IDI1KS4KYC0tanNvbmAgcHJpbnRzIHRoZSBmaW5hbCBzdGF0dXMgcmVzcG9u
>> "!B64TMP!" echo c2UgaW5zdGVhZC4KCklmIHRoZSBjcmF3bCBoYXMgbm90IGZpbmlzaGVkIHdpdGhpbiAtLXRpbWVv
>> "!B64TMP!" echo dXQsIHRoZSBjcmF3bCBJRCBhbmQgY3VycmVudApwcm9ncmVzcyBhcmUgcHJpbnRlZCDigJQga2Vl
>> "!B64TMP!" echo cCBwb2xsaW5nIHdpdGggd2ViX2NyYXdsX3N0YXR1cy5weSA8aWQ+LgoiIiIKaW1wb3J0IGpzb24K
>> "!B64TMP!" echo aW1wb3J0IG9zCmltcG9ydCBzeXMKaW1wb3J0IHRpbWUKCnN5cy5wYXRoLmluc2VydCgwLCBvcy5w
>> "!B64TMP!" echo YXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmlsZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xf
>> "!B64TMP!" echo YXBpIGFzIGZjICAjIHNpYmxpbmc6IEZpcmVjcmF3bCBIVFRQIGNsaWVudCArIHNlbGYtaGVhbAoK
>> "!B64TMP!" echo RU5EUE9JTlQgPSBmYy51cmwoIi92MS9jcmF3bCIpCgojIENyYXdsLWpvYiBzdGF0ZXMgdGhhdCBt
>> "!B64TMP!" echo ZWFuICJubyBtb3JlIHBvbGxpbmciLgpURVJNSU5BTCA9ICgiY29tcGxldGVkIiwgImZhaWxlZCIs
>> "!B64TMP!" echo ICJjYW5jZWxsZWQiLCAic3RvcHBlZCIpCgoKZGVmIGNyYXdsX3N1bW1hcnkoZGF0YSk6CiAgICAi
>> "!B64TMP!" echo IiJPbmUtbGluZSBzdGF0dXMgc3VtbWFyeSBmcm9tIGEgY3Jhd2wtc3RhdHVzIHBheWxvYWQuIiIi
>> "!B64TMP!" echo CiAgICBzdGF0dXMgPSBkYXRhLmdldCgic3RhdHVzIikgb3IgInVua25vd24iCiAgICBjb21wbGV0
>> "!B64TMP!" echo ZWQgPSBkYXRhLmdldCgiY29tcGxldGVkIikKICAgIHRvdGFsID0gZGF0YS5nZXQoInRvdGFsIikK
>> "!B64TMP!" echo ICAgIGlmIGNvbXBsZXRlZCBpcyBub3QgTm9uZSBhbmQgdG90YWwgaXMgbm90IE5vbmU6CiAgICAg
>> "!B64TMP!" echo ICAgcmV0dXJuIGYie3N0YXR1c30gKHtjb21wbGV0ZWR9L3t0b3RhbH0gcGFnZXMpIgogICAgcmV0
>> "!B64TMP!" echo dXJuIHN0cihzdGF0dXMpCgoKZGVmIHByaW50X3BhZ2VzKGRhdGEsIG1heF9wYWdlcywgbWF4X2No
>> "!B64TMP!" echo YXJzKToKICAgICIiIlByaW50IHRoZSBjb2xsZWN0ZWQgcGFnZXM6IGBOLiA8dXJsPmAgKyB0cnVu
>> "!B64TMP!" echo Y2F0ZWQgbWFya2Rvd24uIiIiCiAgICBwYWdlcyA9IGRhdGEuZ2V0KCJkYXRhIikKICAgIGlmIG5v
>> "!B64TMP!" echo dCBpc2luc3RhbmNlKHBhZ2VzLCBsaXN0KSBvciBub3QgcGFnZXM6CiAgICAgICAgcmV0dXJuCiAg
>> "!B64TMP!" echo ICBzaG93biA9IHBhZ2VzWzptYXhfcGFnZXNdCiAgICBmb3IgbiwgcGFnZSBpbiBlbnVtZXJhdGUo
>> "!B64TMP!" echo c2hvd24sIDEpOgogICAgICAgIGlmIG5vdCBpc2luc3RhbmNlKHBhZ2UsIGRpY3QpOgogICAgICAg
>> "!B64TMP!" echo ICAgICBjb250aW51ZQogICAgICAgIHByaW50KGYie259LiB7cGFnZS5nZXQoJ3VybCcpIG9yIHBh
>> "!B64TMP!" echo Z2UuZ2V0KCdzb3VyY2VVUkwnKSBvciAnKG5vIHVybCknfSIpCiAgICAgICAgbWFya2Rvd24gPSBw
>> "!B64TMP!" echo YWdlLmdldCgibWFya2Rvd24iKSBvciAiIgogICAgICAgIGlmIG1hcmtkb3duOgogICAgICAgICAg
>> "!B64TMP!" echo ICBpZiBsZW4obWFya2Rvd24pID4gbWF4X2NoYXJzOgogICAgICAgICAgICAgICAgbWFya2Rvd24g
>> "!B64TMP!" echo PSBtYXJrZG93bls6bWF4X2NoYXJzXSBcCiAgICAgICAgICAgICAgICAgICAgKyBmIlxuICAgWy4u
>> "!B64TMP!" echo LiB0cnVuY2F0ZWQgYXQge21heF9jaGFyc30gY2hhcnMgLi4uXSIKICAgICAgICAgICAgZm9yIGxp
>> "!B64TMP!" echo bmUgaW4gbWFya2Rvd24uc3BsaXRsaW5lcygpIG9yIFsiIl06CiAgICAgICAgICAgICAgICBwcmlu
>> "!B64TMP!" echo dChmIiAgIHtsaW5lfSIpCiAgICBpZiBsZW4ocGFnZXMpID4gbWF4X3BhZ2VzOgogICAgICAgIHBy
>> "!B64TMP!" echo aW50KGYiWy4uLiB7bGVuKHBhZ2VzKSAtIG1heF9wYWdlc30gbW9yZSBwYWdlczsgcmFpc2UgLS1t
>> "!B64TMP!" echo YXgtcGFnZXMgIgogICAgICAgICAgICAgIGYib3IgdXNlIC0tanNvbiAuLi5dIiwgZmlsZT1zeXMu
>> "!B64TMP!" echo c3RkZXJyKQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAg
>> "!B64TMP!" echo aWYgbm90IGFyZ3Mgb3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgIHByaW50KCJ1
>> "!B64TMP!" echo c2FnZTogd2ViX2NyYXdsLnB5IDx1cmw+IFstLXByb21wdCB0ZXh0XSBbLS10aW1lb3V0IFNdICIK
>> "!B64TMP!" echo ICAgICAgICAgICAgICAiWy0tcG9sbC1pbnRlcnZhbCBTXSBbLS1tYXgtcGFnZXMgTl0gWy0tbWF4
>> "!B64TMP!" echo LWNoYXJzIE5dIFstLWpzb25dIiwKICAgICAgICAgICAgICBmaWxlPXN5cy5zdGRlcnIpCiAgICAg
>> "!B64TMP!" echo ICAgcmV0dXJuIDIKICAgIHVybCA9IGFyZ3NbMF0KICAgIHByb21wdCA9IE5vbmUKICAgIHRpbWVv
>> "!B64TMP!" echo dXQsIHBvbGxfZXZlcnkgPSAzMDAsIDIKICAgIG1heF9wYWdlcywgbWF4X2NoYXJzLCBhc19qc29u
>> "!B64TMP!" echo ID0gMjUsIDIwMDAsIEZhbHNlCiAgICBpID0gMQoKICAgIGRlZiBudW0obmFtZSk6CiAgICAgICAg
>> "!B64TMP!" echo IyBgaWAgYWxyZWFkeSBwb2ludHMgYXQgdGhlIG9wdGlvbidzIHZhbHVlICh0aGUgYnJhbmNoIGlu
>> "!B64TMP!" echo Y3JlbWVudGVkIGl0KS4KICAgICAgICB0cnk6CiAgICAgICAgICAgIHJldHVybiBpbnQoYXJnc1tp
>> "!B64TMP!" echo XSkKICAgICAgICBleGNlcHQgKFZhbHVlRXJyb3IsIEluZGV4RXJyb3IpOgogICAgICAgICAgICBw
>> "!B64TMP!" echo cmludChmImludmFsaWQge25hbWV9OiB7YXJnc1tpXSBpZiBpIDwgbGVuKGFyZ3MpIGVsc2UgJyd9
>> "!B64TMP!" echo IiwKICAgICAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBzeXMuZXhp
>> "!B64TMP!" echo dCgyKQoKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAg
>> "!B64TMP!" echo ICBpZiBhID09ICItLXByb21wdCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBp
>> "!B64TMP!" echo ICs9IDEKICAgICAgICAgICAgcHJvbXB0ID0gYXJnc1tpXQogICAgICAgIGVsaWYgYSA9PSAiLS10
>> "!B64TMP!" echo aW1lb3V0IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAg
>> "!B64TMP!" echo ICAgICB0aW1lb3V0ID0gbnVtKCItLXRpbWVvdXQiKQogICAgICAgIGVsaWYgYSA9PSAiLS1wb2xs
>> "!B64TMP!" echo LWludGVydmFsIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAg
>> "!B64TMP!" echo ICAgICAgICBwb2xsX2V2ZXJ5ID0gbnVtKCItLXBvbGwtaW50ZXJ2YWwiKQogICAgICAgIGVsaWYg
>> "!B64TMP!" echo YSA9PSAiLS1tYXgtcGFnZXMiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAgICAgaSAr
>> "!B64TMP!" echo PSAxCiAgICAgICAgICAgIG1heF9wYWdlcyA9IG51bSgiLS1tYXgtcGFnZXMiKQogICAgICAgIGVs
>> "!B64TMP!" echo aWYgYSA9PSAiLS1tYXgtY2hhcnMiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAgICAg
>> "!B64TMP!" echo aSArPSAxCiAgICAgICAgICAgIG1heF9jaGFycyA9IG51bSgiLS1tYXgtY2hhcnMiKQogICAgICAg
>> "!B64TMP!" echo IGVsaWYgYSA9PSAiLS1qc29uIjoKICAgICAgICAgICAgYXNfanNvbiA9IFRydWUKICAgICAgICBl
>> "!B64TMP!" echo bGlmIGEuc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICAgICAgcHJpbnQoZiJ1bmtub3duIG9wdGlv
>> "!B64TMP!" echo bjoge2F9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGVs
>> "!B64TMP!" echo c2U6CiAgICAgICAgICAgIHByaW50KGYidW5leHBlY3RlZCBhcmd1bWVudDoge2F9IiwgZmlsZT1z
>> "!B64TMP!" echo eXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGkgKz0gMQoKICAgIGJvZHkg
>> "!B64TMP!" echo PSB7InVybCI6IHVybH0KICAgIGlmIHByb21wdDoKICAgICAgICBib2R5WyJwcm9tcHQiXSA9IHBy
>> "!B64TMP!" echo b21wdAoKICAgICMgLS0tLSBzdGFydCB0aGUgY3Jhd2wgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgICB0cnk6CiAgICAgICAgc3RhcnRlZCA9IGZjLmNh
>> "!B64TMP!" echo bGwoIi92MS9jcmF3bCIsIG1ldGhvZD0iUE9TVCIsIGJvZHk9Ym9keSkKICAgIGV4Y2VwdCBmYy5G
>> "!B64TMP!" echo Y0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJDUkFXTCBGQUlMRUQgZm9yIHt1cmx9OiB7ZX0i
>> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChl
>> "!B64TMP!" echo LmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQogICAgY3Jhd2xfaWQgPSBz
>> "!B64TMP!" echo dGFydGVkLmdldCgiaWQiKSBvciAoc3RhcnRlZC5nZXQoImRhdGEiKSBvciB7fSkuZ2V0KCJpZCIp
>> "!B64TMP!" echo CiAgICBpZiBub3QgY3Jhd2xfaWQ6CiAgICAgICAgcHJpbnQoIkNSQVdMIEZBSUxFRCBmb3Ige306
>> "!B64TMP!" echo IHRoZSBBUEkgZGlkIG5vdCByZXR1cm4gYSBjcmF3bCBpZC4gIgogICAgICAgICAgICAgICJSZXNw
>> "!B64TMP!" echo b25zZToiLmZvcm1hdCh1cmwpLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcHJpbnQoanNvbi5k
>> "!B64TMP!" echo dW1wcyhzdGFydGVkKVs6ODAwXSwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCiAg
>> "!B64TMP!" echo ICBwcmludChmIkNyYXdsIHN0YXJ0ZWQ6IHtjcmF3bF9pZH0iLCBmaWxlPXN5cy5zdGRlcnIpCgog
>> "!B64TMP!" echo ICAgIyAtLS0tIHBvbGwgdG8gYSB0ZXJtaW5hbCBzdGF0ZSAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0KICAgIGRlYWRsaW5lID0gdGltZS50aW1lKCkgKyB0aW1lb3V0CiAg
>> "!B64TMP!" echo ICB3aGlsZSBUcnVlOgogICAgICAgIHRyeToKICAgICAgICAgICAgZGF0YSA9IGZjLmNhbGwoIi92
>> "!B64TMP!" echo MS9jcmF3bC8iICsgc3RyKGNyYXdsX2lkKSwgbWV0aG9kPSJHRVQiKQogICAgICAgIGV4Y2VwdCBm
>> "!B64TMP!" echo Yy5GY0Vycm9yIGFzIGU6CiAgICAgICAgICAgIHByaW50KGYiQ1JBV0wgRkFJTEVEIGZvciB7dXJs
>> "!B64TMP!" echo fTogc3RhdHVzIGNoZWNrIGZhaWxlZDoge2V9IiwKICAgICAgICAgICAgICAgICAgZmlsZT1zeXMu
>> "!B64TMP!" echo c3RkZXJyKQogICAgICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgICAgICBwcmludChlLmhp
>> "!B64TMP!" echo bnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDEKICAgICAgICBzdGF0dXMg
>> "!B64TMP!" echo PSBzdHIoZGF0YS5nZXQoInN0YXR1cyIpIG9yICJ1bmtub3duIikKICAgICAgICBpZiBzdGF0dXMg
>> "!B64TMP!" echo aW4gVEVSTUlOQUwgb3IgKHN0YXR1cyBub3QgaW4KICAgICAgICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICgiYWN0aXZlIiwgInNjcmFwaW5nIiwgInF1ZXVlZCIsICJwcm9jZXNzaW5nIiwKICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAid2FpdGluZyIsICJydW5uaW5nIikgYW5k
>> "!B64TMP!" echo IGRhdGEuZ2V0KCJkYXRhIikpOgogICAgICAgICAgICBicmVhawogICAgICAgIGlmIHRpbWUudGlt
>> "!B64TMP!" echo ZSgpID49IGRlYWRsaW5lOgogICAgICAgICAgICBwcmludChmIkNyYXdsIHtjcmF3bF9pZH0gc3Rp
>> "!B64TMP!" echo bGwge2NyYXdsX3N1bW1hcnkoZGF0YSl9IGFmdGVyICIKICAgICAgICAgICAgICAgICAgZiJ7dGlt
>> "!B64TMP!" echo ZW91dH1zIOKAlCBrZWVwaW5nIHBvbGxpbmcgd2l0aDoiLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAg
>> "!B64TMP!" echo ICAgICAgIHByaW50KGYiICAgIHB5dGhvbiB3ZWJfY3Jhd2xfc3RhdHVzLnB5IHtjcmF3bF9pZH0i
>> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIGlmIGFzX2pzb246CiAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICBwcmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgcHJpbnQoZiJDcmF3bCB7Y3Jhd2xfaWR9OiB7Y3Jhd2xfc3VtbWFyeShkYXRhKX0gKHRpbWVk
>> "!B64TMP!" echo IG91dCkiKQogICAgICAgICAgICByZXR1cm4gMQogICAgICAgIHByaW50KGYiICBjcmF3bCB7Y3Jh
>> "!B64TMP!" echo d2xfaWR9OiB7Y3Jhd2xfc3VtbWFyeShkYXRhKX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
>> "!B64TMP!" echo dGltZS5zbGVlcChtYXgocG9sbF9ldmVyeSwgMSkpCgogICAgaWYgYXNfanNvbjoKICAgICAgICBw
>> "!B64TMP!" echo cmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwIGlmIHN0YXR1cyA9PSAiY29t
>> "!B64TMP!" echo cGxldGVkIiBlbHNlIDEKCiAgICBpZiBzdGF0dXMgIT0gImNvbXBsZXRlZCI6CiAgICAgICAgcHJp
>> "!B64TMP!" echo bnQoZiJDUkFXTCBGQUlMRUQgZm9yIHt1cmx9OiBjcmF3bCB7Y3Jhd2xfaWR9IGVuZGVkIGFzICIK
>> "!B64TMP!" echo ICAgICAgICAgICAgICBmIlwie3N0YXR1c31cIi4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
>> "!B64TMP!" echo cHJpbnQoanNvbi5kdW1wcyhkYXRhKVs6ODAwXSwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJl
>> "!B64TMP!" echo dHVybiAxCgogICAgY3JlZGl0cyA9IGRhdGEuZ2V0KCJjcmVkaXRzVXNlZCIpCiAgICBzdWZmaXgg
>> "!B64TMP!" echo PSBmIiwge2NyZWRpdHN9IGNyZWRpdHMgdXNlZCIgaWYgY3JlZGl0cyBpcyBub3QgTm9uZSBlbHNl
>> "!B64TMP!" echo ICIiCiAgICBwcmludChmIkNyYXdsIHtjcmF3bF9pZH06IHtjcmF3bF9zdW1tYXJ5KGRhdGEpfXtz
>> "!B64TMP!" echo dWZmaXh9IikKICAgIHByaW50X3BhZ2VzKGRhdGEsIG1heF9wYWdlcywgbWF4X2NoYXJzKQogICAg
>> "!B64TMP!" echo cmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigp
>> "!B64TMP!" echo KQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_crawl.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_crawl_status.py ---
set "B64TMP=%TEMP%\LSR2062759972.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZXQgdGhlIHN0YXR1cywgcHJvZ3Jlc3MsIGFuZCBh
>> "!B64TMP!" echo dmFpbGFibGUgcmVzdWx0cyBvZiBhbiBleGlzdGluZyBGaXJlY3Jhd2wKY3Jhd2wgKHRoZSBmaXJl
>> "!B64TMP!" echo Y3Jhd2xfY2hlY2tfY3Jhd2xfc3RhdHVzIE1DUCB0b29sKS4KClVzYWdlOgogICAgcHl0aG9uIHdl
>> "!B64TMP!" echo Yl9jcmF3bF9zdGF0dXMucHkgPGlkPiBbLS1tYXgtcGFnZXMgTl0gWy0tbWF4LWNoYXJzIE5dIFst
>> "!B64TMP!" echo LWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFj
>> "!B64TMP!" echo aGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNj
>> "!B64TMP!" echo cmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVf
>> "!B64TMP!" echo c3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBm
>> "!B64TMP!" echo YWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0
>> "!B64TMP!" echo cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVf
>> "!B64TMP!" echo c3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpQcmludHMgYENyYXdsIDxp
>> "!B64TMP!" echo ZD46IDxzdGF0dXM+IChjb21wbGV0ZWQvdG90YWwgcGFnZXMpYDsgd2hlbiB0aGUgY3Jhd2wgaGFz
>> "!B64TMP!" echo CmZpbmlzaGVkLCB0aGUgY29sbGVjdGVkIHBhZ2VzIGZvbGxvdyBhcyBgTi4gPHVybD5gICsgbWFy
>> "!B64TMP!" echo a2Rvd24gdHJ1bmNhdGVkIGF0Ci0tbWF4LWNoYXJzIGNoYXJzIChkZWZhdWx0IDIwMDA7IHVwIHRv
>> "!B64TMP!" echo IC0tbWF4LXBhZ2VzIHBhZ2VzLCBkZWZhdWx0IDI1KS4KYC0tanNvbmAgcHJpbnRzIHRoZSByYXcg
>> "!B64TMP!" echo QVBJIHJlc3BvbnNlIGluc3RlYWQuIFRoZSBzdGF0dXMgcXVlcnkgaXRzZWxmIG9ubHkKZmFpbHMg
>> "!B64TMP!" echo KGV4aXQgMSkgd2hlbiB0aGUgQVBJIGNhbm5vdCBiZSByZWFjaGVkOyBhIGBmYWlsZWRgIGNyYXds
>> "!B64TMP!" echo IHN0aWxsIGV4aXRzIDAuCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lz
>> "!B64TMP!" echo LnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18p
>> "!B64TMP!" echo KSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAg
>> "!B64TMP!" echo Y2xpZW50ICsgc2VsZi1oZWFsCmltcG9ydCB3ZWJfY3Jhd2wgICMgc2libGluZzogc2hhcmVkIGNy
>> "!B64TMP!" echo YXdsIG91dHB1dCBmb3JtYXR0aW5nCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL2NyYXdsIikKCgpk
>> "!B64TMP!" echo ZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBhcmdz
>> "!B64TMP!" echo IG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdlYl9j
>> "!B64TMP!" echo cmF3bF9zdGF0dXMucHkgPGlkPiBbLS1tYXgtcGFnZXMgTl0gWy0tbWF4LWNoYXJzIE5dICIKICAg
>> "!B64TMP!" echo ICAgICAgICAgICAiWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIK
>> "!B64TMP!" echo ICAgIGNyYXdsX2lkID0gYXJnc1swXQogICAgbWF4X3BhZ2VzLCBtYXhfY2hhcnMsIGFzX2pzb24g
>> "!B64TMP!" echo PSAyNSwgMjAwMCwgRmFsc2UKICAgIGkgPSAxCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAg
>> "!B64TMP!" echo ICAgIGEgPSBhcmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1tYXgtcGFnZXMiIGFuZCBpICsgMSA8
>> "!B64TMP!" echo IGxlbihhcmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIHRyeToKICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgIG1heF9wYWdlcyA9IGludChhcmdzW2ldKQogICAgICAgICAgICBleGNlcHQgVmFsdWVF
>> "!B64TMP!" echo cnJvcjoKICAgICAgICAgICAgICAgIHByaW50KGYiaW52YWxpZCAtLW1heC1wYWdlczoge2FyZ3Nb
>> "!B64TMP!" echo aV19IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBl
>> "!B64TMP!" echo bGlmIGEgPT0gIi0tbWF4LWNoYXJzIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAg
>> "!B64TMP!" echo IGkgKz0gMQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQo
>> "!B64TMP!" echo YXJnc1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBw
>> "!B64TMP!" echo cmludChmImludmFsaWQgLS1tYXgtY2hhcnM6IHthcmdzW2ldfSIsIGZpbGU9c3lzLnN0ZGVycikK
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLWpzb24iOgogICAg
>> "!B64TMP!" echo ICAgICAgICBhc19qc29uID0gVHJ1ZQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgog
>> "!B64TMP!" echo ICAgICAgICAgICBwcmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIp
>> "!B64TMP!" echo CiAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcHJpbnQoZiJ1
>> "!B64TMP!" echo bmV4cGVjdGVkIGFyZ3VtZW50OiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJl
>> "!B64TMP!" echo dHVybiAyCiAgICAgICAgaSArPSAxCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIv
>> "!B64TMP!" echo djEvY3Jhd2wvIiArIHN0cihjcmF3bF9pZCksIG1ldGhvZD0iR0VUIikKICAgIGV4Y2VwdCBmYy5G
>> "!B64TMP!" echo Y0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJDUkFXTCBTVEFUVVMgRkFJTEVEIGZvciB7Y3Jh
>> "!B64TMP!" echo d2xfaWR9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAg
>> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAg
>> "!B64TMP!" echo IGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1
>> "!B64TMP!" echo cm4gMAoKICAgIHByaW50KGYiQ3Jhd2wge2NyYXdsX2lkfToge3dlYl9jcmF3bC5jcmF3bF9zdW1t
>> "!B64TMP!" echo YXJ5KGRhdGEpfSIpCiAgICB3ZWJfY3Jhd2wucHJpbnRfcGFnZXMoZGF0YSwgbWF4X3BhZ2VzLCBt
>> "!B64TMP!" echo YXhfY2hhcnMpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBz
>> "!B64TMP!" echo eXMuZXhpdChtYWluKCkpCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_crawl_status.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_agent.py ---
set "B64TMP=%TEMP%\LSR3807948473.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTdGFydCBhbiBhc3luY2hyb25vdXMgRmlyZWNyYXds
>> "!B64TMP!" echo IHJlc2VhcmNoIGFnZW50IGpvYiAodGhlIGZpcmVjcmF3bF9hZ2VudApNQ1AgdG9vbCk6IGdpdmUg
>> "!B64TMP!" echo aXQgYSBwcm9tcHQsIG9wdGlvbmFsIHNlZWQgVVJMcywgYW5kIHJlYWQgdGhlIHJlc3VsdCBsYXRl
>> "!B64TMP!" echo cgp3aXRoIHdlYl9hZ2VudF9zdGF0dXMucHkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJfYWdlbnQu
>> "!B64TMP!" echo cHkgIjxwcm9tcHQ+IiBbc2VlZF91cmwgLi4uXSBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0
>> "!B64TMP!" echo aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRo
>> "!B64TMP!" echo ZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMg
>> "!B64TMP!" echo dGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJl
>> "!B64TMP!" echo dHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRy
>> "!B64TMP!" echo YW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYu
>> "!B64TMP!" echo CllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1
>> "!B64TMP!" echo biB0aGUgc2NyaXB0LgoKVGhlIGZpcnN0IGFyZ3VtZW50IGlzIHRoZSByZXNlYXJjaCBwcm9tcHQg
>> "!B64TMP!" echo KHF1b3RlIGl0KTsgYW55IGZ1cnRoZXIgcG9zaXRpb25hbAphcmd1bWVudHMgYXJlIHNlZWQgVVJM
>> "!B64TMP!" echo cyB0aGUgYWdlbnQgc2hvdWxkIHN0YXJ0IGZyb20uIFRoaXMgY2FsbCBvbmx5IFNUQVJUUwp0aGUg
>> "!B64TMP!" echo am9iIGFuZCBwcmludHMgaXRzIElEIOKAlCB0aGUgcmVzZWFyY2ggaXRzZWxmIGNvbW1vbmx5IHRh
>> "!B64TMP!" echo a2VzIHNldmVyYWwKbWludXRlcywgc28gcG9sbCB0aGUgam9iIHVudGlsIGl0IGlzIGNvbXBsZXRl
>> "!B64TMP!" echo ZCBvciBmYWlsZWQ6CgogICAgcHl0aG9uIHdlYl9hZ2VudF9zdGF0dXMucHkgPGlkPgoKYC0tanNv
>> "!B64TMP!" echo bmAgcHJpbnRzIHRoZSByYXcgQVBJIHJlc3BvbnNlIGluc3RlYWQgb2YgdGhlIHN1bW1hcnkuCiIi
>> "!B64TMP!" echo IgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9z
>> "!B64TMP!" echo LnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3
>> "!B64TMP!" echo bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFs
>> "!B64TMP!" echo CgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL2FnZW50IikKCgpkZWYgbWFpbigpIC0+IGludDoKICAg
>> "!B64TMP!" echo IGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBhcmdzIG9yIGFyZ3NbMF0uc3RhcnRzd2l0
>> "!B64TMP!" echo aCgiLS0iKToKICAgICAgICBwcmludCgndXNhZ2U6IHdlYl9hZ2VudC5weSAiPHByb21wdD4iIFtz
>> "!B64TMP!" echo ZWVkX3VybCAuLi5dIFstLWpzb25dJywKICAgICAgICAgICAgICBmaWxlPXN5cy5zdGRlcnIpCiAg
>> "!B64TMP!" echo ICAgICAgcmV0dXJuIDIKICAgIHByb21wdCA9IGFyZ3NbMF0KICAgIHVybHMsIGFzX2pzb24gPSBb
>> "!B64TMP!" echo XSwgRmFsc2UKICAgIGkgPSAxCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAgICAgIGEgPSBh
>> "!B64TMP!" echo cmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1qc29uIjoKICAgICAgICAgICAgYXNfanNvbiA9IFRy
>> "!B64TMP!" echo dWUKICAgICAgICBlbGlmIGEuc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICAgICAgcHJpbnQoZiJ1
>> "!B64TMP!" echo bmtub3duIG9wdGlvbjoge2F9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4g
>> "!B64TMP!" echo MgogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHVybHMuYXBwZW5kKGEpCiAgICAgICAgaSArPSAx
>> "!B64TMP!" echo CgogICAgYm9keSA9IHsicHJvbXB0IjogcHJvbXB0fQogICAgaWYgdXJsczoKICAgICAgICBib2R5
>> "!B64TMP!" echo WyJ1cmxzIl0gPSB1cmxzCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIvdjEvYWdl
>> "!B64TMP!" echo bnQiLCBtZXRob2Q9IlBPU1QiLCBib2R5PWJvZHkpCiAgICBleGNlcHQgZmMuRmNFcnJvciBhcyBl
>> "!B64TMP!" echo OgogICAgICAgIHByaW50KGYiQUdFTlQgU1RBUlQgRkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRl
>> "!B64TMP!" echo cnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lz
>> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQo
>> "!B64TMP!" echo anNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAoKICAgIHBheWxvYWQgPSBkYXRhLmdl
>> "!B64TMP!" echo dCgiZGF0YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRh
>> "!B64TMP!" echo CiAgICBqb2JfaWQgPSBwYXlsb2FkLmdldCgiaWQiKSBvciBkYXRhLmdldCgiaWQiKQogICAgaWYg
>> "!B64TMP!" echo bm90IGpvYl9pZDoKICAgICAgICBwcmludCgiQUdFTlQgU1RBUlQgRkFJTEVEOiB0aGUgQVBJIGRp
>> "!B64TMP!" echo ZCBub3QgcmV0dXJuIGEgam9iIGlkLiBSZXNwb25zZToiLAogICAgICAgICAgICAgIGZpbGU9c3lz
>> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpWzo4MDBdLCBmaWxlPXN5cy5z
>> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgcmV0dXJuIDEKICAgIHByaW50KGYiQWdlbnQgam9iIHN0YXJ0ZWQ6IHtq
>> "!B64TMP!" echo b2JfaWR9IikKICAgIGlmIHVybHM6CiAgICAgICAgcHJpbnQoZiJTZWVkIFVSTHM6IHsnLCAnLmpv
>> "!B64TMP!" echo aW4odXJscyl9IikKICAgIHByaW50KCJSZXNlYXJjaCBjb21tb25seSB0YWtlcyBzZXZlcmFsIG1p
>> "!B64TMP!" echo bnV0ZXMg4oCUIHBvbGwgd2l0aDoiKQogICAgcHJpbnQoZiIgICAgcHl0aG9uIHdlYl9hZ2VudF9z
>> "!B64TMP!" echo dGF0dXMucHkge2pvYl9pZH0iKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWlu
>> "!B64TMP!" echo X18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_agent.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_agent_status.py ---
set "B64TMP=%TEMP%\LSR1968784321.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZXQgdGhlIHByb2dyZXNzIG9yIGZpbmFsIHJlc3Vs
>> "!B64TMP!" echo dHMgb2YgYSBGaXJlY3Jhd2wgcmVzZWFyY2ggYWdlbnQgam9iICh0aGUKZmlyZWNyYXdsX2FnZW50
>> "!B64TMP!" echo X3N0YXR1cyBNQ1AgdG9vbCksIHN0YXJ0ZWQgd2l0aCB3ZWJfYWdlbnQucHkuCgpVc2FnZToKICAg
>> "!B64TMP!" echo IHB5dGhvbiB3ZWJfYWdlbnRfc3RhdHVzLnB5IDxpZD4gWy0tanNvbl0KClNlbGYtaGVhbGluZzog
>> "!B64TMP!" echo aWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBv
>> "!B64TMP!" echo ciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3Rh
>> "!B64TMP!" echo cnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFu
>> "!B64TMP!" echo ZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVzCnNlbGYtaGVhbCBvbmNl
>> "!B64TMP!" echo OyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdpdGggYSBzaG9ydCBiYWNr
>> "!B64TMP!" echo b2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5weSBmaXJzdCDigJQganVz
>> "!B64TMP!" echo dCBydW4gdGhlIHNjcmlwdC4KClByaW50cyBgQWdlbnQgPGlkPjogPHN0YXR1cz5gLiBBIGBwcm9j
>> "!B64TMP!" echo ZXNzaW5nYC9gYWN0aXZlYCBzdGF0dXMgaXMgbm9uLXRlcm1pbmFsCuKAlCBjaGVjayBhZ2FpbiBh
>> "!B64TMP!" echo ZnRlciAxNS0zMCBzLiBXaGVuIHRoZSBqb2IgaXMgYGNvbXBsZXRlZGAsIHRoZSByZXNlYXJjaCBy
>> "!B64TMP!" echo ZXN1bHQKZm9sbG93cyAoc3RlcHMsIHNvdXJjZXMsIGFuZCB0aGUgZmluYWwgYW5zd2VyL3JlcG9y
>> "!B64TMP!" echo dCBhcyByZXR1cm5lZCBieSB0aGUgQVBJKTsKYGZhaWxlZGAgam9icyBwcmludCB0aGUgYXZhaWxh
>> "!B64TMP!" echo YmxlIGVycm9yIGRldGFpbHMgYW5kIGV4aXQgMS4gYC0tanNvbmAgcHJpbnRzCnRoZSByYXcgQVBJ
>> "!B64TMP!" echo IHJlc3BvbnNlIGluc3RlYWQuCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoK
>> "!B64TMP!" echo c3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxl
>> "!B64TMP!" echo X18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhU
>> "!B64TMP!" echo VFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL2FnZW50IikKCgpk
>> "!B64TMP!" echo ZWYgcHJpbnRfcmVzdWx0KHJlc3VsdCwgaW5kZW50PTApOgogICAgIiIiUmVjdXJzaXZlbHkgcHJp
>> "!B64TMP!" echo bnQgdGhlIGFnZW50IHJlc3VsdCBpbiBhIHJlYWRhYmxlIG91dGxpbmUuIiIiCiAgICBwYWQgPSAi
>> "!B64TMP!" echo ICIgKiBpbmRlbnQKICAgIGlmIGlzaW5zdGFuY2UocmVzdWx0LCBkaWN0KToKICAgICAgICBmb3Ig
>> "!B64TMP!" echo a2V5LCB2YWwgaW4gcmVzdWx0Lml0ZW1zKCk6CiAgICAgICAgICAgIGlmIGlzaW5zdGFuY2UodmFs
>> "!B64TMP!" echo LCAoZGljdCwgbGlzdCkpOgogICAgICAgICAgICAgICAgcHJpbnQoZiJ7cGFkfXtrZXl9OiIpCiAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICBwcmludF9yZXN1bHQodmFsLCBpbmRlbnQgKyAyKQogICAgICAgICAgICBl
>> "!B64TMP!" echo bHNlOgogICAgICAgICAgICAgICAgdGV4dCA9IHN0cih2YWwpCiAgICAgICAgICAgICAgICBpZiBs
>> "!B64TMP!" echo ZW4odGV4dCkgPiA0MDAwOgogICAgICAgICAgICAgICAgICAgIHRleHQgPSB0ZXh0Wzo0MDAwXSAr
>> "!B64TMP!" echo IGYiXG57cGFkfVsuLi4gdHJ1bmNhdGVkIC4uLl0iCiAgICAgICAgICAgICAgICBwcmludChmIntw
>> "!B64TMP!" echo YWR9e2tleX06IHt0ZXh0fSIpCiAgICBlbGlmIGlzaW5zdGFuY2UocmVzdWx0LCBsaXN0KToKICAg
>> "!B64TMP!" echo ICAgICBmb3IgbiwgaXRlbSBpbiBlbnVtZXJhdGUocmVzdWx0LCAxKToKICAgICAgICAgICAgcHJp
>> "!B64TMP!" echo bnQoZiJ7cGFkfXtufS4iKQogICAgICAgICAgICBwcmludF9yZXN1bHQoaXRlbSwgaW5kZW50ICsg
>> "!B64TMP!" echo MikKICAgIGVsc2U6CiAgICAgICAgdGV4dCA9IHN0cihyZXN1bHQpCiAgICAgICAgaWYgbGVuKHRl
>> "!B64TMP!" echo eHQpID4gNDAwMDoKICAgICAgICAgICAgdGV4dCA9IHRleHRbOjQwMDBdICsgZiJcbntwYWR9Wy4u
>> "!B64TMP!" echo LiB0cnVuY2F0ZWQgLi4uXSIKICAgICAgICBwcmludChwYWQgKyB0ZXh0KQoKCmRlZiBtYWluKCkg
>> "!B64TMP!" echo LT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mgb3IgYXJnc1sw
>> "!B64TMP!" echo XS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX2FnZW50X3N0YXR1
>> "!B64TMP!" echo cy5weSA8aWQ+IFstLWpzb25dIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCiAg
>> "!B64TMP!" echo ICBqb2JfaWQgPSBhcmdzWzBdCiAgICBhc19qc29uID0gIi0tanNvbiIgaW4gYXJnc1sxOl0KCiAg
>> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNhbGwoIi92MS9hZ2VudC8iICsgc3RyKGpvYl9pZCks
>> "!B64TMP!" echo IG1ldGhvZD0iR0VUIikKICAgIGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQo
>> "!B64TMP!" echo ZiJBR0VOVCBTVEFUVVMgRkFJTEVEIGZvciB7am9iX2lkfToge2V9IiwgZmlsZT1zeXMuc3RkZXJy
>> "!B64TMP!" echo KQogICAgICAgIGlmIGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxlPXN5cy5z
>> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAgICAgIHByaW50KGpz
>> "!B64TMP!" echo b24uZHVtcHMoZGF0YSkpCiAgICAgICAgcmV0dXJuIDAgaWYgZGF0YS5nZXQoInN0YXR1cyIpICE9
>> "!B64TMP!" echo ICJmYWlsZWQiIGVsc2UgMQoKICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0YSIpIGlmIGlzaW5z
>> "!B64TMP!" echo dGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRhCiAgICBzdGF0dXMgPSBzdHIo
>> "!B64TMP!" echo cGF5bG9hZC5nZXQoInN0YXR1cyIpIG9yIGRhdGEuZ2V0KCJzdGF0dXMiKSBvciAidW5rbm93biIp
>> "!B64TMP!" echo CiAgICBwcmludChmIkFnZW50IHtqb2JfaWR9OiB7c3RhdHVzfSIpCiAgICBpZiBzdGF0dXMgbm90
>> "!B64TMP!" echo IGluICgiY29tcGxldGVkIiwgImZhaWxlZCIsICJjYW5jZWxsZWQiLCAic3RvcHBlZCIpOgogICAg
>> "!B64TMP!" echo ICAgIHByaW50KCIobm9uLXRlcm1pbmFsIOKAlCBjaGVjayBhZ2FpbiBhZnRlciAxNS0zMCBzKSIp
>> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIDAKICAgIHJlc3VsdCA9IHBheWxvYWQuZ2V0KCJyZXN1bHQiKQogICAg
>> "!B64TMP!" echo aWYgcmVzdWx0IGlzIE5vbmU6CiAgICAgICAgcmVzdWx0ID0gZGF0YS5nZXQoInJlc3VsdCIpCiAg
>> "!B64TMP!" echo ICBpZiByZXN1bHQgaXMgbm90IE5vbmU6CiAgICAgICAgcHJpbnQoKQogICAgICAgIHByaW50X3Jl
>> "!B64TMP!" echo c3VsdChyZXN1bHQpCiAgICBlbGlmIHN0YXR1cyA9PSAiZmFpbGVkIjoKICAgICAgICBlcnJvciA9
>> "!B64TMP!" echo IHBheWxvYWQuZ2V0KCJlcnJvciIpIG9yIGRhdGEuZ2V0KCJlcnJvciIpCiAgICAgICAgcHJpbnQo
>> "!B64TMP!" echo ZiJlcnJvcjoge2Vycm9yIG9yICcobm8gZGV0YWlscyByZXR1cm5lZCknfSIpCiAgICByZXR1cm4g
>> "!B64TMP!" echo MCBpZiBzdGF0dXMgPT0gImNvbXBsZXRlZCIgZWxzZSAxCgoKaWYgX19uYW1lX18gPT0gIl9fbWFp
>> "!B64TMP!" echo bl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_agent_status.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_interact.py ---
set "B64TMP=%TEMP%\LSR1793725509.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJJbnRlcmFjdCB3aXRoIGEgc2NyYXBlZCBwYWdlIHRo
>> "!B64TMP!" echo cm91Z2ggYSBsaXZlIEZpcmVjcmF3bCBicm93c2VyIHNlc3Npb24KKHRoZSBmaXJlY3Jhd2xfaW50
>> "!B64TMP!" echo ZXJhY3QgTUNQIHRvb2wpOiBuYXZpZ2F0ZSwgY2xpY2sgY29udHJvbHMsIGZpbGwgZmllbGRzLCBv
>> "!B64TMP!" echo cgpydW4gYnJvd3NlciBjb2RlLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2ludGVyYWN0LnB5ICgt
>> "!B64TMP!" echo LXNjcmFwZS1pZCBJRCB8IC0tdXJsIFVSTCkKICAgICAgICAgICAgICAgICAgICAgICAgICAgKC0t
>> "!B64TMP!" echo cHJvbXB0IFRFWFQgfCAtLWNvZGUgVEVYVCBbLS1sYW5ndWFnZSBiYXNofHB5dGhvbnxub2RlXSkK
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgWy0tdGltZW91dCBTXSBbLS1qc29uXQoKU2VsZi1o
>> "!B64TMP!" echo ZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIg
>> "!B64TMP!" echo ZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGlj
>> "!B64TMP!" echo YWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVu
>> "!B64TMP!" echo LmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1o
>> "!B64TMP!" echo ZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNo
>> "!B64TMP!" echo b3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0
>> "!B64TMP!" echo IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJvdmlkZSBFSVRIRVIgLS1zY3JhcGUtaWQgKHJl
>> "!B64TMP!" echo dXNlIGEgcHJldmlvdXMgc2NyYXBlJ3Mgc2Vzc2lvbikgb3IgLS11cmwKKG9wZW4gYSBmcmVzaCBz
>> "!B64TMP!" echo ZXNzaW9uKSwgYW5kIEVJVEhFUiAtLXByb21wdCAobmF0dXJhbC1sYW5ndWFnZSBpbnN0cnVjdGlv
>> "!B64TMP!" echo bnMpCm9yIC0tY29kZSAod2l0aCAtLWxhbmd1YWdlLCBkZWZhdWx0IGJhc2gpLiBOT1RFOiB0aGlz
>> "!B64TMP!" echo IGFjdHMgb24gdGhlIExJVkUgc2l0ZSDigJQKYWN0aW9ucyBzdWNoIGFzIGZvcm0gc3VibWlzc2lv
>> "!B64TMP!" echo biBjYW4gY3JlYXRlIHBlcnNpc3RlbnQgZXh0ZXJuYWwgc2lkZSBlZmZlY3RzLgoKUHJpbnRzIHRo
>> "!B64TMP!" echo ZSBBUEkncyBKU09OIHJlc3BvbnNlOiBleGVjdXRpb24gb3V0cHV0LCBzdGRvdXQvc3RkZXJyLCBl
>> "!B64TMP!" echo eGl0CnN0YXR1cywgYW5kIHRoZSBzZXNzaW9uIHZpZXdpbmcgVVJMcy4gYC0tanNvbmAgcHJpbnRz
>> "!B64TMP!" echo IGl0IGNvbXBhY3Qgb24gb25lIGxpbmUKaW5zdGVhZCBvZiBwcmV0dHktcHJpbnRlZC4KIiIiCmlt
>> "!B64TMP!" echo cG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0
>> "!B64TMP!" echo aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXdsX2Fw
>> "!B64TMP!" echo aSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwKCkVO
>> "!B64TMP!" echo RFBPSU5UID0gZmMudXJsKCIvdjEvaW50ZXJhY3QiKQoKTEFOR1VBR0VTID0gKCJiYXNoIiwgInB5
>> "!B64TMP!" echo dGhvbiIsICJub2RlIikKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsx
>> "!B64TMP!" echo Ol0KICAgIHNjcmFwZV9pZCwgdXJsID0gTm9uZSwgTm9uZQogICAgcHJvbXB0LCBjb2RlLCBsYW5n
>> "!B64TMP!" echo dWFnZSA9IE5vbmUsIE5vbmUsIE5vbmUKICAgIHRpbWVvdXQsIGFzX2pzb24gPSBOb25lLCBGYWxz
>> "!B64TMP!" echo ZQogICAgaSA9IDAKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0K
>> "!B64TMP!" echo ICAgICAgICBpZiBhID09ICItLXNjcmFwZS1pZCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAg
>> "!B64TMP!" echo ICAgICAgICBpICs9IDEKICAgICAgICAgICAgc2NyYXBlX2lkID0gYXJnc1tpXQogICAgICAgIGVs
>> "!B64TMP!" echo aWYgYSA9PSAiLS11cmwiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAgICAgaSArPSAx
>> "!B64TMP!" echo CiAgICAgICAgICAgIHVybCA9IGFyZ3NbaV0KICAgICAgICBlbGlmIGEgPT0gIi0tcHJvbXB0IiBh
>> "!B64TMP!" echo bmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICBwcm9t
>> "!B64TMP!" echo cHQgPSBhcmdzW2ldCiAgICAgICAgZWxpZiBhID09ICItLWNvZGUiIGFuZCBpICsgMSA8IGxlbihh
>> "!B64TMP!" echo cmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIGNvZGUgPSBhcmdzW2ldCiAgICAg
>> "!B64TMP!" echo ICAgZWxpZiBhID09ICItLWxhbmd1YWdlIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAg
>> "!B64TMP!" echo ICAgIGkgKz0gMQogICAgICAgICAgICBsYW5ndWFnZSA9IGFyZ3NbaV0KICAgICAgICAgICAgaWYg
>> "!B64TMP!" echo bGFuZ3VhZ2Ugbm90IGluIExBTkdVQUdFUzoKICAgICAgICAgICAgICAgIHByaW50KGYiaW52YWxp
>> "!B64TMP!" echo ZCAtLWxhbmd1YWdlOiB7bGFuZ3VhZ2V9ICIKICAgICAgICAgICAgICAgICAgICAgIGYiKG9uZSBv
>> "!B64TMP!" echo ZiB7JywgJy5qb2luKExBTkdVQUdFUyl9KSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLXRpbWVvdXQiIGFuZCBpICsgMSA8IGxl
>> "!B64TMP!" echo bihhcmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgIHRpbWVvdXQgPSBpbnQoYXJnc1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6
>> "!B64TMP!" echo CiAgICAgICAgICAgICAgICBwcmludChmImludmFsaWQgLS10aW1lb3V0OiB7YXJnc1tpXX0iLCBm
>> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGVsaWYgYSA9
>> "!B64TMP!" echo PSAiLS1qc29uIjoKICAgICAgICAgICAgYXNfanNvbiA9IFRydWUKICAgICAgICBlbGlmIGEuc3Rh
>> "!B64TMP!" echo cnRzd2l0aCgiLS0iKToKICAgICAgICAgICAgcHJpbnQoZiJ1bmtub3duIG9wdGlvbjoge2F9Iiwg
>> "!B64TMP!" echo ZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGVsc2U6CiAgICAg
>> "!B64TMP!" echo ICAgICAgIHByaW50KGYidW5leHBlY3RlZCBhcmd1bWVudDoge2F9IiwgZmlsZT1zeXMuc3RkZXJy
>> "!B64TMP!" echo KQogICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGkgKz0gMQoKICAgIGlmIGJvb2woc2NyYXBl
>> "!B64TMP!" echo X2lkKSA9PSBib29sKHVybCk6CiAgICAgICAgcHJpbnQoInByb3ZpZGUgZXhhY3RseSBvbmUgb2Yg
>> "!B64TMP!" echo LS1zY3JhcGUtaWQgKHJldXNlIGEgc2NyYXBlJ3Mgc2Vzc2lvbikgIgogICAgICAgICAgICAgICJv
>> "!B64TMP!" echo ciAtLXVybCAob3BlbiBhIG5ldyBzZXNzaW9uKSwgbm90IGJvdGgiLCBmaWxlPXN5cy5zdGRlcnIp
>> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIDIKICAgIGlmIG5vdCBwcm9tcHQgYW5kIG5vdCBjb2RlOgogICAgICAg
>> "!B64TMP!" echo IHByaW50KCJwcm92aWRlIGVpdGhlciAtLXByb21wdCAobmF0dXJhbCBsYW5ndWFnZSkgb3IgLS1j
>> "!B64TMP!" echo b2RlICIKICAgICAgICAgICAgICAiKGV4ZWN1dGFibGUsIHdpdGggLS1sYW5ndWFnZSkiLCBmaWxl
>> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKICAgIGlmIGxhbmd1YWdlIGFuZCBub3QgY29k
>> "!B64TMP!" echo ZToKICAgICAgICBwcmludCgiLS1sYW5ndWFnZSBjYW4gb25seSBiZSB1c2VkIHRvZ2V0aGVyIHdp
>> "!B64TMP!" echo dGggLS1jb2RlIiwKICAgICAgICAgICAgICBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJu
>> "!B64TMP!" echo IDIKCiAgICBib2R5ID0ge30KICAgIGlmIHNjcmFwZV9pZDoKICAgICAgICBib2R5WyJzY3JhcGVJ
>> "!B64TMP!" echo ZCJdID0gc2NyYXBlX2lkCiAgICBlbHNlOgogICAgICAgIGJvZHlbInVybCJdID0gdXJsCiAgICBp
>> "!B64TMP!" echo ZiBwcm9tcHQ6CiAgICAgICAgYm9keVsicHJvbXB0Il0gPSBwcm9tcHQKICAgIGlmIGNvZGU6CiAg
>> "!B64TMP!" echo ICAgICAgYm9keVsiY29kZSJdID0gY29kZQogICAgICAgIGJvZHlbImxhbmd1YWdlIl0gPSBsYW5n
>> "!B64TMP!" echo dWFnZSBvciAiYmFzaCIKICAgIGlmIHRpbWVvdXQgaXMgbm90IE5vbmU6CiAgICAgICAgYm9keVsi
>> "!B64TMP!" echo dGltZW91dCJdID0gdGltZW91dAoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3Yx
>> "!B64TMP!" echo L2ludGVyYWN0IiwgbWV0aG9kPSJQT1NUIiwgYm9keT1ib2R5KQogICAgZXhjZXB0IGZjLkZjRXJy
>> "!B64TMP!" echo b3IgYXMgZToKICAgICAgICBwcmludChmIklOVEVSQUNUIEZBSUxFRDoge2V9IiwgZmlsZT1zeXMu
>> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIGlmIGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxl
>> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBwcmludChqc29uLmR1bXBzKGRhdGEp
>> "!B64TMP!" echo IGlmIGFzX2pzb24gZWxzZSBqc29uLmR1bXBzKGRhdGEsIGluZGVudD0yKSkKICAgIHJldHVybiAw
>> "!B64TMP!" echo CgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_interact.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_interact_stop.py ---
set "B64TMP=%TEMP%\LSR466171262.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTdG9wIHRoZSBsaXZlIEZpcmVjcmF3bCBpbnRlcmFj
>> "!B64TMP!" echo dCBzZXNzaW9uIGZvciBhIHNjcmFwZUlkIGFuZCByZWxlYXNlIGl0cwpyZXNvdXJjZXMgKHRoZSBm
>> "!B64TMP!" echo aXJlY3Jhd2xfaW50ZXJhY3Rfc3RvcCBNQ1AgdG9vbCkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
>> "!B64TMP!" echo aW50ZXJhY3Rfc3RvcC5weSA8c2NyYXBlSWQ+IFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRo
>> "!B64TMP!" echo ZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhl
>> "!B64TMP!" echo CmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0
>> "!B64TMP!" echo aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0
>> "!B64TMP!" echo cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJh
>> "!B64TMP!" echo bnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4K
>> "!B64TMP!" echo WW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVu
>> "!B64TMP!" echo IHRoZSBzY3JpcHQuCgpQcmludHMgYSBjb25maXJtYXRpb24gKHBsdXMgdGhlIEFQSSdzIHJlc3Bv
>> "!B64TMP!" echo bnNlIGJvZHkgd2hlbiBvbmUgaXMgcmV0dXJuZWQpLgpgLS1qc29uYCBwcmludHMgdGhlIHJhdyBB
>> "!B64TMP!" echo UEkgcmVzcG9uc2UgaW5zdGVhZC4gVGhlIHNlc3Npb24gY2Fubm90IGJlIHJlc3VtZWQKYWZ0ZXIg
>> "!B64TMP!" echo aXQgaXMgc3RvcHBlZC4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMu
>> "!B64TMP!" echo cGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykp
>> "!B64TMP!" echo KQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBj
>> "!B64TMP!" echo bGllbnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvaW50ZXJhY3QiKQoKCmRl
>> "!B64TMP!" echo ZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mg
>> "!B64TMP!" echo b3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX2lu
>> "!B64TMP!" echo dGVyYWN0X3N0b3AucHkgPHNjcmFwZUlkPiBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
>> "!B64TMP!" echo ICAgICByZXR1cm4gMgogICAgc2NyYXBlX2lkID0gYXJnc1swXQogICAgYXNfanNvbiA9ICItLWpz
>> "!B64TMP!" echo b24iIGluIGFyZ3NbMTpdCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIvdjEvaW50
>> "!B64TMP!" echo ZXJhY3QvIiArIHN0cihzY3JhcGVfaWQpICsgIi9zdG9wIiwKICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICBtZXRob2Q9IlBPU1QiKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmlu
>> "!B64TMP!" echo dChmIklOVEVSQUNUIFNUT1AgRkFJTEVEIGZvciB7c2NyYXBlX2lkfToge2V9IiwgZmlsZT1zeXMu
>> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIGlmIGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxl
>> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAgICAgIHBy
>> "!B64TMP!" echo aW50KGpzb24uZHVtcHMoZGF0YSkpCiAgICAgICAgcmV0dXJuIDAKICAgIHByaW50KGYiSW50ZXJh
>> "!B64TMP!" echo Y3Qgc2Vzc2lvbiB7c2NyYXBlX2lkfSBzdG9wcGVkLiIpCiAgICBpZiBkYXRhOgogICAgICAgIHBy
>> "!B64TMP!" echo aW50KGpzb24uZHVtcHMoZGF0YSwgaW5kZW50PTIpKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVf
>> "!B64TMP!" echo XyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_interact_stop.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_parse.py ---
set "B64TMP=%TEMP%\LSR1598028764.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJQYXJzZSBhIGxvY2FsIGRvY3VtZW50IGludG8gbWFy
>> "!B64TMP!" echo a2Rvd24gLyBIVE1MIC8gbGlua3MgLyBhIHN1bW1hcnkgLyB0YXJnZXRlZAphbnN3ZXJzIC8gc3Ry
>> "!B64TMP!" echo dWN0dXJlZCBKU09OICh0aGUgZmlyZWNyYXdsX3BhcnNlIE1DUCB0b29sKS4gU3VwcG9ydGVkIGlu
>> "!B64TMP!" echo cHV0cwppbmNsdWRlIGNvbW1vbiBIVE1MLCBQREYsIFdvcmQsIFJURiwgT3BlbkRvY3VtZW50LCBh
>> "!B64TMP!" echo bmQgc3ByZWFkc2hlZXQgZmlsZXMuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJfcGFyc2UucHkgPGZp
>> "!B64TMP!" echo bGVQYXRoPiBbLS1mb3JtYXRzIG1hcmtkb3duLGxpbmtzLC4uLl0gWy0tbWF4LWNoYXJzIE5dCiAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgIFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2Nh
>> "!B64TMP!" echo bC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRh
>> "!B64TMP!" echo aW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0
>> "!B64TMP!" echo aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0
>> "!B64TMP!" echo aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZS4gWW91IGRvIE5P
>> "!B64TMP!" echo VCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZQpzY3Jp
>> "!B64TMP!" echo cHQuCgpUaGUgZmlsZSBpcyB1cGxvYWRlZCB0byB0aGUgbG9jYWwgRmlyZWNyYXdsIGluc3RhbmNl
>> "!B64TMP!" echo IChpdCBuZXZlciBsZWF2ZXMgeW91cgptYWNoaW5lKS4gYC0tZm9ybWF0c2AgdGFrZXMgYSBjb21t
>> "!B64TMP!" echo YS1zZXBhcmF0ZWQgbGlzdCBmcm9tOiBtYXJrZG93biwgaHRtbCwKcmF3SHRtbCwgbGlua3MsIHN1
>> "!B64TMP!" echo bW1hcnksIGpzb24sIHF1ZXJ5IChkZWZhdWx0OiBtYXJrZG93bikuIFByaW50cyB0aGUgcGFyc2Vk
>> "!B64TMP!" echo CmNvbnRlbnQ7IHdpdGggc2V2ZXJhbCBmb3JtYXRzIGVhY2ggaXMgcHJpbnRlZCB1bmRlciBhIGAj
>> "!B64TMP!" echo IyA8Zm9ybWF0PmAgaGVhZGVyLgpNYXJrZG93bi9IVE1MIHRydW5jYXRlIGF0IC0tbWF4LWNoYXJz
>> "!B64TMP!" echo IGNoYXJzIChkZWZhdWx0IDIwMDAwLCBsaWtlCndlYl9zY3JhcGUucHkpLiBgLS1qc29uYCBwcmlu
>> "!B64TMP!" echo dHMgdGhlIHJhdyBBUEkgcmVzcG9uc2UgaW5zdGVhZC4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBv
>> "!B64TMP!" echo cwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGgu
>> "!B64TMP!" echo YWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5n
>> "!B64TMP!" echo OiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIv
>> "!B64TMP!" echo djEvcGFyc2UiKQoKRk9STUFUUyA9ICgibWFya2Rvd24iLCAiaHRtbCIsICJyYXdIdG1sIiwgImxp
>> "!B64TMP!" echo bmtzIiwgInN1bW1hcnkiLCAianNvbiIsICJxdWVyeSIpCgojIEV4dGVuc2lvbiAtPiBNSU1FIHR5
>> "!B64TMP!" echo cGUgZm9yIHRoZSB1cGxvYWQgKGV2ZXJ5dGhpbmcgZWxzZSBpcyBzZW50IGFzIGEKIyBnZW5lcmlj
>> "!B64TMP!" echo IG9jdGV0IHN0cmVhbSBhbmQgRmlyZWNyYXdsIHNuaWZmcyB0aGUgcmVhbCB0eXBlIHNlcnZlci1z
>> "!B64TMP!" echo aWRlKS4KTUlNRV9UWVBFUyA9IHsKICAgICIuaHRtbCI6ICJ0ZXh0L2h0bWwiLCAiLmh0bSI6ICJ0
>> "!B64TMP!" echo ZXh0L2h0bWwiLAogICAgIi5wZGYiOiAiYXBwbGljYXRpb24vcGRmIiwKICAgICIuZG9jIjogImFw
>> "!B64TMP!" echo cGxpY2F0aW9uL21zd29yZCIsCiAgICAiLmRvY3giOiAiYXBwbGljYXRpb24vdm5kLm9wZW54bWxm
>> "!B64TMP!" echo b3JtYXRzLW9mZmljZWRvY3VtZW50LndvcmRwcm9jZXNzaW5nbWwuZG9jdW1lbnQiLAogICAgIi5y
>> "!B64TMP!" echo dGYiOiAiYXBwbGljYXRpb24vcnRmIiwKICAgICIub2R0IjogImFwcGxpY2F0aW9uL3ZuZC5vYXNp
>> "!B64TMP!" echo cy5vcGVuZG9jdW1lbnQudGV4dCIsCiAgICAiLm9kcyI6ICJhcHBsaWNhdGlvbi92bmQub2FzaXMu
>> "!B64TMP!" echo b3BlbmRvY3VtZW50LnNwcmVhZHNoZWV0IiwKICAgICIueGxzIjogImFwcGxpY2F0aW9uL3ZuZC5t
>> "!B64TMP!" echo cy1leGNlbCIsCiAgICAiLnhsc3giOiAiYXBwbGljYXRpb24vdm5kLm9wZW54bWxmb3JtYXRzLW9m
>> "!B64TMP!" echo ZmljZWRvY3VtZW50LnNwcmVhZHNoZWV0bWwuc2hlZXQiLAogICAgIi5jc3YiOiAidGV4dC9jc3Yi
>> "!B64TMP!" echo LAogICAgIi50eHQiOiAidGV4dC9wbGFpbiIsCiAgICAiLm1kIjogInRleHQvbWFya2Rvd24iLAp9
>> "!B64TMP!" echo CgojIEZvcm1hdHMgd2hvc2UgY29udGVudCBpcyBwbGFpbiB0ZXh0IGFuZCBjYW4gYmUgdHJ1bmNh
>> "!B64TMP!" echo dGVkIHNhZmVseS4KVEVYVF9GT1JNQVRTID0gKCJtYXJrZG93biIsICJodG1sIiwgInJhd0h0bWwi
>> "!B64TMP!" echo LCAic3VtbWFyeSIsICJxdWVyeSIpCgoKZGVmIGNvbnRlbnRfdHlwZV9mb3IocGF0aCk6CiAgICBy
>> "!B64TMP!" echo ZXR1cm4gTUlNRV9UWVBFUy5nZXQob3MucGF0aC5zcGxpdGV4dChwYXRoKVsxXS5sb3dlcigpLAog
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICJhcHBsaWNhdGlvbi9vY3RldC1zdHJlYW0iKQoKCmRl
>> "!B64TMP!" echo ZiBwcmludF9maWVsZChuYW1lLCB2YWx1ZSwgbWF4X2NoYXJzKToKICAgICIiIlByaW50IG9uZSBw
>> "!B64TMP!" echo YXJzZWQgZm9ybWF0IHVuZGVyIGEgaGVhZGVyLCB0cnVuY2F0aW5nIGxvbmcgdGV4dC4iIiIKICAg
>> "!B64TMP!" echo IGlmIG5hbWUgIT0gIm1hcmtkb3duIjoKICAgICAgICBwcmludChmIiMjIHtuYW1lfSIpCiAgICBp
>> "!B64TMP!" echo ZiBpc2luc3RhbmNlKHZhbHVlLCBsaXN0KToKICAgICAgICBmb3IgbiwgaXRlbSBpbiBlbnVtZXJh
>> "!B64TMP!" echo dGUodmFsdWUsIDEpOgogICAgICAgICAgICBwcmludChmIntufS4ge2l0ZW19IikKICAgICAgICBy
>> "!B64TMP!" echo ZXR1cm4KICAgIGlmIGlzaW5zdGFuY2UodmFsdWUsIChkaWN0LCBib29sLCBpbnQsIGZsb2F0KSk6
>> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyh2YWx1ZSwgaW5kZW50PTIpKQogICAgICAgIHJldHVy
>> "!B64TMP!" echo bgogICAgdGV4dCA9IHN0cih2YWx1ZSkKICAgIGlmIG5vdCB0ZXh0OgogICAgICAgIHByaW50KCIo
>> "!B64TMP!" echo ZW1wdHkpIikKICAgICAgICByZXR1cm4KICAgIGlmIG5hbWUgaW4gVEVYVF9GT1JNQVRTIGFuZCBs
>> "!B64TMP!" echo ZW4odGV4dCkgPiBtYXhfY2hhcnM6CiAgICAgICAgdGV4dCA9IHRleHRbOm1heF9jaGFyc10gKyBm
>> "!B64TMP!" echo IlxuWy4uLiB0cnVuY2F0ZWQgYXQge21heF9jaGFyc30gY2hhcnMgLi4uXSIKICAgIHByaW50KHRl
>> "!B64TMP!" echo eHQpCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBpZiBu
>> "!B64TMP!" echo b3QgYXJncyBvciBhcmdzWzBdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgcHJpbnQoInVzYWdl
>> "!B64TMP!" echo OiB3ZWJfcGFyc2UucHkgPGZpbGVQYXRoPiBbLS1mb3JtYXRzIG1hcmtkb3duLGxpbmtzLC4uLl0g
>> "!B64TMP!" echo IgogICAgICAgICAgICAgICJbLS1tYXgtY2hhcnMgTl0gWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRl
>> "!B64TMP!" echo cnIpCiAgICAgICAgcmV0dXJuIDIKICAgIGZpbGVfcGF0aCA9IGFyZ3NbMF0KICAgIGZvcm1hdHMg
>> "!B64TMP!" echo PSBbIm1hcmtkb3duIl0KICAgIG1heF9jaGFycywgYXNfanNvbiA9IDIwMDAwLCBGYWxzZQogICAg
>> "!B64TMP!" echo aSA9IDEKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAg
>> "!B64TMP!" echo ICBpZiBhID09ICItLWZvcm1hdHMiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAgICAg
>> "!B64TMP!" echo aSArPSAxCiAgICAgICAgICAgIGZvcm1hdHMgPSBbZi5zdHJpcCgpIGZvciBmIGluIGFyZ3NbaV0u
>> "!B64TMP!" echo c3BsaXQoIiwiKSBpZiBmLnN0cmlwKCldCiAgICAgICAgICAgIGJhZCA9IFtmIGZvciBmIGluIGZv
>> "!B64TMP!" echo cm1hdHMgaWYgZiBub3QgaW4gRk9STUFUU10KICAgICAgICAgICAgaWYgYmFkOgogICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgcHJpbnQoZiJpbnZhbGlkIC0tZm9ybWF0cyB2YWx1ZShzKTogeycsICcuam9pbihiYWQp
>> "!B64TMP!" echo fSAiCiAgICAgICAgICAgICAgICAgICAgICBmIih2YWxpZDogeycsICcuam9pbihGT1JNQVRTKX0p
>> "!B64TMP!" echo IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlm
>> "!B64TMP!" echo IGEgPT0gIi0tbWF4LWNoYXJzIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkg
>> "!B64TMP!" echo Kz0gMQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQoYXJn
>> "!B64TMP!" echo c1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBwcmlu
>> "!B64TMP!" echo dChmImludmFsaWQgLS1tYXgtY2hhcnM6IHthcmdzW2ldfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLWpzb24iOgogICAgICAg
>> "!B64TMP!" echo ICAgICBhc19qc29uID0gVHJ1ZQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAg
>> "!B64TMP!" echo ICAgICAgICBwcmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAg
>> "!B64TMP!" echo ICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcHJpbnQoZiJ1bmV4
>> "!B64TMP!" echo cGVjdGVkIGFyZ3VtZW50OiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVy
>> "!B64TMP!" echo biAyCiAgICAgICAgaSArPSAxCgogICAgaWYgbm90IG9zLnBhdGguaXNmaWxlKGZpbGVfcGF0aCk6
>> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoZiJQQVJTRSBGQUlMRUQ6IG5vIHN1Y2ggZmlsZToge2ZpbGVfcGF0aH0i
>> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBvcHRpb25zID0geyJmb3Jt
>> "!B64TMP!" echo YXRzIjogZm9ybWF0c30KICAgIGZpZWxkcyA9IHsib3B0aW9ucyI6IGpzb24uZHVtcHMob3B0aW9u
>> "!B64TMP!" echo cyksCiAgICAgICAgICAgICAgImNvbnRlbnRUeXBlIjogY29udGVudF90eXBlX2ZvcihmaWxlX3Bh
>> "!B64TMP!" echo dGgpfQogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsX2Zvcm0oIi92MS9wYXJzZSIsIGZp
>> "!B64TMP!" echo ZWxkcywgZmlsZV9wYXRoKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmlu
>> "!B64TMP!" echo dChmIlBBUlNFIEZBSUxFRCBmb3Ige2ZpbGVfcGF0aH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikK
>> "!B64TMP!" echo ICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMuc3Rk
>> "!B64TMP!" echo ZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChqc29u
>> "!B64TMP!" echo LmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCgogICAgcGF5bG9hZCA9IGRhdGEuZ2V0KCJk
>> "!B64TMP!" echo YXRhIikgaWYgaXNpbnN0YW5jZShkYXRhLmdldCgiZGF0YSIpLCBkaWN0KSBlbHNlIGRhdGEKICAg
>> "!B64TMP!" echo IHByaW50ZWQgPSAwCiAgICBmb3IgZm10IGluIGZvcm1hdHM6CiAgICAgICAgdmFsdWUgPSBwYXls
>> "!B64TMP!" echo b2FkLmdldChmbXQpCiAgICAgICAgaWYgdmFsdWUgaXMgTm9uZToKICAgICAgICAgICAgY29udGlu
>> "!B64TMP!" echo dWUKICAgICAgICBpZiBwcmludGVkOgogICAgICAgICAgICBwcmludCgpCiAgICAgICAgcHJpbnRf
>> "!B64TMP!" echo ZmllbGQoZm10LCB2YWx1ZSwgbWF4X2NoYXJzKQogICAgICAgIHByaW50ZWQgKz0gMQogICAgaWYg
>> "!B64TMP!" echo bm90IHByaW50ZWQ6CiAgICAgICAgcHJpbnQoZiJQQVJTRSBSRVRVUk5FRCBOTyBDT05URU5UIGZv
>> "!B64TMP!" echo ciB7ZmlsZV9wYXRofSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludChqc29uLmR1bXBz
>> "!B64TMP!" echo KGRhdGEpWzo4MDBdLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKICAgIHJldHVy
>> "!B64TMP!" echo biAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_parse.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_monitor_create.py ---
set "B64TMP=%TEMP%\LSR4176321923.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJDcmVhdGUgYSByZWN1cnJpbmcgRmlyZWNyYXdsIG1v
>> "!B64TMP!" echo bml0b3Ig4oCUIGEgc2NyYXBlLCBjcmF3bCwgb3Igc2VhcmNoIGNoZWNrCnRoYXQgY29tcGFyZXMg
>> "!B64TMP!" echo ZWFjaCBydW4gd2l0aCBpdHMgcmV0YWluZWQgcHJlZGVjZXNzb3IgKHRoZQpmaXJlY3Jhd2xfbW9u
>> "!B64TMP!" echo aXRvcl9jcmVhdGUgTUNQIHRvb2wpLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX21vbml0b3JfY3Jl
>> "!B64TMP!" echo YXRlLnB5ICgtLWJvZHkgJ3suLi59JyB8IC0tYm9keS1maWxlIG1vbml0b3IuanNvbikKICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgWy0tanNvbl0KClNlbGYtaGVhbGluZzogaWYgdGhl
>> "!B64TMP!" echo IGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0aGUK
>> "!B64TMP!" echo Y29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRzIHRo
>> "!B64TMP!" echo ZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCByZXRy
>> "!B64TMP!" echo aWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVzCnNlbGYtaGVhbCBvbmNlOyB0cmFu
>> "!B64TMP!" echo c2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdpdGggYSBzaG9ydCBiYWNrb2ZmLgpZ
>> "!B64TMP!" echo b3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5weSBmaXJzdCDigJQganVzdCBydW4g
>> "!B64TMP!" echo dGhlIHNjcmlwdC4KCmAtLWJvZHlgIGlzIHRoZSBmdWxsIG1vbml0b3IgY29uZmlndXJhdGlvbiBh
>> "!B64TMP!" echo cyBKU09OIChzYW1lIG9iamVjdCB0aGUgTUNQCnRvb2wncyBgYm9keWAgcGFyYW1ldGVyIHRha2Vz
>> "!B64TMP!" echo OiBuYW1lLCBzY2hlZHVsZSwgZ29hbCwgdGFyZ2V0cywgd2ViaG9vaywKbm90aWZpY2F0aW9uLCBy
>> "!B64TMP!" echo ZXRlbnRpb24sIC4uLikuIGAtLWJvZHktZmlsZWAgcmVhZHMgaXQgZnJvbSBhIGZpbGUgaW5zdGVh
>> "!B64TMP!" echo ZC4KUHJpbnRzIHRoZSBjcmVhdGVkIG1vbml0b3IgYXMgcHJldHR5IEpTT047IGAtLWpzb25gIHBy
>> "!B64TMP!" echo aW50cyB0aGUgcmF3IEFQSQpyZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEg
>> "!B64TMP!" echo RmlyZWNyYXdsIEFDQ09VTlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApG
>> "!B64TMP!" echo SVJFQ1JBV0xfQVBJX0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVj
>> "!B64TMP!" echo cmF3bC5kZXYgZm9yIHRoZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5v
>> "!B64TMP!" echo dCBleHBvc2UgdGhlbS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMu
>> "!B64TMP!" echo cGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykp
>> "!B64TMP!" echo KQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBj
>> "!B64TMP!" echo bGllbnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVm
>> "!B64TMP!" echo IHJlYWRfYm9keV9hcmcoYXJncyk6CiAgICAiIiJSZXR1cm4gdGhlIG1vbml0b3IgYm9keSBhcyBh
>> "!B64TMP!" echo IGRpY3QgZnJvbSAtLWJvZHkgLyAtLWJvZHktZmlsZSwgb3IKICAgIChOb25lLCBlcnJvci1tZXNz
>> "!B64TMP!" echo YWdlKS4iIiIKICAgIGJvZHlfcmF3LCBib2R5X2ZpbGUgPSBOb25lLCBOb25lCiAgICBpID0gMAog
>> "!B64TMP!" echo ICAgd2hpbGUgaSA8IGxlbihhcmdzKToKICAgICAgICBhID0gYXJnc1tpXQogICAgICAgIGlmIGEg
>> "!B64TMP!" echo PT0gIi0tYm9keSIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBpICs9IDEKICAg
>> "!B64TMP!" echo ICAgICAgICAgYm9keV9yYXcgPSBhcmdzW2ldCiAgICAgICAgZWxpZiBhID09ICItLWJvZHktZmls
>> "!B64TMP!" echo ZSIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAg
>> "!B64TMP!" echo Ym9keV9maWxlID0gYXJnc1tpXQogICAgICAgIGkgKz0gMQogICAgaWYgYm9keV9yYXcgaXMgbm90
>> "!B64TMP!" echo IE5vbmUgYW5kIGJvZHlfZmlsZSBpcyBub3QgTm9uZToKICAgICAgICByZXR1cm4gTm9uZSwgInBy
>> "!B64TMP!" echo b3ZpZGUgZWl0aGVyIC0tYm9keSBvciAtLWJvZHktZmlsZSwgbm90IGJvdGgiCiAgICBpZiBib2R5
>> "!B64TMP!" echo X2ZpbGUgaXMgbm90IE5vbmU6CiAgICAgICAgdHJ5OgogICAgICAgICAgICB3aXRoIG9wZW4oYm9k
>> "!B64TMP!" echo eV9maWxlLCBlbmNvZGluZz0idXRmLTgiKSBhcyBmaDoKICAgICAgICAgICAgICAgIGJvZHlfcmF3
>> "!B64TMP!" echo ID0gZmgucmVhZCgpCiAgICAgICAgZXhjZXB0IE9TRXJyb3IgYXMgZToKICAgICAgICAgICAgcmV0
>> "!B64TMP!" echo dXJuIE5vbmUsICJjb3VsZCBub3QgcmVhZCB7fToge30iLmZvcm1hdChib2R5X2ZpbGUsIGUpCiAg
>> "!B64TMP!" echo ICBpZiBib2R5X3JhdyBpcyBOb25lOgogICAgICAgIHJldHVybiBOb25lLCAoImEgbW9uaXRvciBi
>> "!B64TMP!" echo b2R5IGlzIHJlcXVpcmVkOiAtLWJvZHkgJ3suLi59JyAiCiAgICAgICAgICAgICAgICAgICAgICAi
>> "!B64TMP!" echo KGZ1bGwgbW9uaXRvciBKU09OKSBvciAtLWJvZHktZmlsZSBGSUxFIikKICAgIHRyeToKICAgICAg
>> "!B64TMP!" echo ICBib2R5ID0ganNvbi5sb2Fkcyhib2R5X3JhdykKICAgIGV4Y2VwdCBWYWx1ZUVycm9yIGFzIGU6
>> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIE5vbmUsICJ0aGUgYm9keSBpcyBub3QgdmFsaWQgSlNPTjoge30iLmZv
>> "!B64TMP!" echo cm1hdChlKQogICAgaWYgbm90IGlzaW5zdGFuY2UoYm9keSwgZGljdCk6CiAgICAgICAgcmV0dXJu
>> "!B64TMP!" echo IE5vbmUsICJ0aGUgbW9uaXRvciBib2R5IG11c3QgYmUgYSBKU09OIG9iamVjdCIKICAgIHJldHVy
>> "!B64TMP!" echo biBib2R5LCBOb25lCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpd
>> "!B64TMP!" echo CiAgICBhc19qc29uID0gIi0tanNvbiIgaW4gYXJncwogICAgYm9keSwgZXJyID0gcmVhZF9ib2R5
>> "!B64TMP!" echo X2FyZyhhcmdzKQogICAgaWYgZXJyOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX21vbml0b3Jf
>> "!B64TMP!" echo Y3JlYXRlLnB5ICgtLWJvZHkgJ3suLi59JyB8ICIKICAgICAgICAgICAgICAiLS1ib2R5LWZpbGUg
>> "!B64TMP!" echo bW9uaXRvci5qc29uKSBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludChl
>> "!B64TMP!" echo cnIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgoKICAgIHRyeToKICAgICAgICBk
>> "!B64TMP!" echo YXRhID0gZmMuY2FsbCgiL3YxL21vbml0b3IiLCBtZXRob2Q9IlBPU1QiLCBib2R5PWJvZHkpCiAg
>> "!B64TMP!" echo ICBleGNlcHQgZmMuRmNFcnJvciBhcyBlOgogICAgICAgIHByaW50KGYiTU9OSVRPUiBDUkVBVEUg
>> "!B64TMP!" echo RkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAg
>> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAg
>> "!B64TMP!" echo IGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1
>> "!B64TMP!" echo cm4gMAogICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhLCBpbmRlbnQ9MikpCiAgICByZXR1cm4gMAoK
>> "!B64TMP!" echo CmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_monitor_create.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_monitor_list.py ---
set "B64TMP=%TEMP%\LSR2268657624.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJMaXN0IHRoZSBGaXJlY3Jhd2wgbW9uaXRvcnMgb2Yg
>> "!B64TMP!" echo dGhlIGF1dGhlbnRpY2F0ZWQgYWNjb3VudCAodGhlCmZpcmVjcmF3bF9tb25pdG9yX2xpc3QgTUNQ
>> "!B64TMP!" echo IHRvb2wpLCB3aXRoIG9wdGlvbmFsIHBhZ2luYXRpb24uCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
>> "!B64TMP!" echo bW9uaXRvcl9saXN0LnB5IFstLWxpbWl0IE5dIFstLW9mZnNldCBOXSBbLS1qc29uXQoKU2VsZi1o
>> "!B64TMP!" echo ZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIg
>> "!B64TMP!" echo ZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGlj
>> "!B64TMP!" echo YWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVu
>> "!B64TMP!" echo LmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1o
>> "!B64TMP!" echo ZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNo
>> "!B64TMP!" echo b3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0
>> "!B64TMP!" echo IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIG9uZSBsaW5lIHBlciBtb25pdG9yOiBg
>> "!B64TMP!" echo Ti4gPGlkPiDigJQgPG5hbWU+ICg8c3RhdGU+KWAuIGAtLWpzb25gIHByaW50cwp0aGUgcmF3IEFQ
>> "!B64TMP!" echo SSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFDQ09V
>> "!B64TMP!" echo TlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJX0tF
>> "!B64TMP!" echo WSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yIHRo
>> "!B64TMP!" echo ZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4K
>> "!B64TMP!" echo IiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwg
>> "!B64TMP!" echo b3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNy
>> "!B64TMP!" echo YXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhl
>> "!B64TMP!" echo YWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVmIG1haW4oKSAtPiBpbnQ6
>> "!B64TMP!" echo CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBsaW1pdCwgb2Zmc2V0LCBhc19qc29uID0gTm9u
>> "!B64TMP!" echo ZSwgTm9uZSwgRmFsc2UKICAgIGkgPSAwCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAgICAg
>> "!B64TMP!" echo IGEgPSBhcmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1saW1pdCIgYW5kIGkgKyAxIDwgbGVuKGFy
>> "!B64TMP!" echo Z3MpOgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAg
>> "!B64TMP!" echo bGltaXQgPSBpbnQoYXJnc1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICBwcmludChmImludmFsaWQgLS1saW1pdDoge2FyZ3NbaV19IiwgZmlsZT1zeXMu
>> "!B64TMP!" echo c3RkZXJyKQogICAgICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tb2Zm
>> "!B64TMP!" echo c2V0IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAg
>> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgICAgICAgICBvZmZzZXQgPSBpbnQoYXJnc1tpXSkKICAgICAgICAgICAg
>> "!B64TMP!" echo ZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBwcmludChmImludmFsaWQgLS1vZmZz
>> "!B64TMP!" echo ZXQ6IHthcmdzW2ldfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgICAgIHJldHVybiAy
>> "!B64TMP!" echo CiAgICAgICAgZWxpZiBhID09ICItLWpzb24iOgogICAgICAgICAgICBhc19qc29uID0gVHJ1ZQog
>> "!B64TMP!" echo ICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgICAgICBwcmludChmInVua25v
>> "!B64TMP!" echo d24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAyCiAg
>> "!B64TMP!" echo ICAgICAgZWxzZToKICAgICAgICAgICAgcHJpbnQoZiJ1bmV4cGVjdGVkIGFyZ3VtZW50OiB7YX0i
>> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgaSArPSAxCgog
>> "!B64TMP!" echo ICAgcXVlcnkgPSB7fQogICAgaWYgbGltaXQgaXMgbm90IE5vbmU6CiAgICAgICAgcXVlcnlbImxp
>> "!B64TMP!" echo bWl0Il0gPSBsaW1pdAogICAgaWYgb2Zmc2V0IGlzIG5vdCBOb25lOgogICAgICAgIHF1ZXJ5WyJv
>> "!B64TMP!" echo ZmZzZXQiXSA9IG9mZnNldAoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL21v
>> "!B64TMP!" echo bml0b3IiLCBtZXRob2Q9IkdFVCIsIHF1ZXJ5PXF1ZXJ5KQogICAgZXhjZXB0IGZjLkZjRXJyb3Ig
>> "!B64TMP!" echo YXMgZToKICAgICAgICBwcmludChmIk1PTklUT1IgTElTVCBGQUlMRUQ6IHtlfSIsIGZpbGU9c3lz
>> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmls
>> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBw
>> "!B64TMP!" echo cmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCgogICAgbW9uaXRvcnMgPSBk
>> "!B64TMP!" echo YXRhLmdldCgibW9uaXRvcnMiKQogICAgaWYgbm90IGlzaW5zdGFuY2UobW9uaXRvcnMsIGxpc3Qp
>> "!B64TMP!" echo OgogICAgICAgIG1vbml0b3JzID0gZGF0YS5nZXQoImRhdGEiKQogICAgaWYgbm90IGlzaW5zdGFu
>> "!B64TMP!" echo Y2UobW9uaXRvcnMsIGxpc3QpOgogICAgICAgIG1vbml0b3JzID0gZGF0YSBpZiBpc2luc3RhbmNl
>> "!B64TMP!" echo KGRhdGEsIGxpc3QpIGVsc2UgW10KICAgIGlmIG5vdCBtb25pdG9yczoKICAgICAgICBwcmludCgi
>> "!B64TMP!" echo KG5vIG1vbml0b3JzKSIpCiAgICAgICAgcmV0dXJuIDAKICAgIGZvciBuLCBtb25pdG9yIGluIGVu
>> "!B64TMP!" echo dW1lcmF0ZShtb25pdG9ycywgMSk6CiAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UobW9uaXRvciwg
>> "!B64TMP!" echo ZGljdCk6CiAgICAgICAgICAgIHByaW50KGYie259LiB7bW9uaXRvcn0iKQogICAgICAgICAgICBj
>> "!B64TMP!" echo b250aW51ZQogICAgICAgIG1pZCA9IG1vbml0b3IuZ2V0KCJpZCIpIG9yIG1vbml0b3IuZ2V0KCJt
>> "!B64TMP!" echo b25pdG9ySWQiKSBvciAiPyIKICAgICAgICBuYW1lID0gbW9uaXRvci5nZXQoIm5hbWUiKSBvciAi
>> "!B64TMP!" echo KHVubmFtZWQpIgogICAgICAgIHN0YXRlID0gKG1vbml0b3IuZ2V0KCJzdGF0ZSIpIG9yIG1vbml0
>> "!B64TMP!" echo b3IuZ2V0KCJzdGF0dXMiKQogICAgICAgICAgICAgICAgIG9yICgiYWN0aXZlIiBpZiBtb25pdG9y
>> "!B64TMP!" echo LmdldCgiYWN0aXZlIikgZWxzZSAicGF1c2VkIikpCiAgICAgICAgcHJpbnQoZiJ7bn0uIHttaWR9
>> "!B64TMP!" echo IOKAlCB7bmFtZX0gKHtzdGF0ZX0pIikKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9f
>> "!B64TMP!" echo bWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_monitor_list.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_monitor_get.py ---
set "B64TMP=%TEMP%\LSR823213229.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZXRyaWV2ZSBvbmUgRmlyZWNyYXdsIG1vbml0b3Ig
>> "!B64TMP!" echo YnkgSUQsIGluY2x1ZGluZyBpdHMgY29uZmlndXJhdGlvbiBhbmQKY3VycmVudCBzdGF0ZSAodGhl
>> "!B64TMP!" echo IGZpcmVjcmF3bF9tb25pdG9yX2dldCBNQ1AgdG9vbCkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
>> "!B64TMP!" echo bW9uaXRvcl9nZXQucHkgPGlkPiBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwt
>> "!B64TMP!" echo c2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWlu
>> "!B64TMP!" echo ZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhl
>> "!B64TMP!" echo IHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhl
>> "!B64TMP!" echo IHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0
>> "!B64TMP!" echo MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBO
>> "!B64TMP!" echo T1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2Ny
>> "!B64TMP!" echo aXB0LgoKUHJpbnRzIHRoZSBtb25pdG9yIGFzIHByZXR0eSBKU09OLiBgLS1qc29uYCBwcmludHMg
>> "!B64TMP!" echo dGhlIHJhdyBBUEkgcmVzcG9uc2UKaW5zdGVhZC4gVGhpcyBkb2VzIG5vdCBydW4gb3IgbW9kaWZ5
>> "!B64TMP!" echo IHRoZSBtb25pdG9yLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFDQ09VTlQgZmVh
>> "!B64TMP!" echo dHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJX0tFWSwgYW5k
>> "!B64TMP!" echo IEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yIHRoZQpjbG91
>> "!B64TMP!" echo ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4KIiIiCmlt
>> "!B64TMP!" echo cG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0
>> "!B64TMP!" echo aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXdsX2Fw
>> "!B64TMP!" echo aSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwKCkVO
>> "!B64TMP!" echo RFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBh
>> "!B64TMP!" echo cmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBpZiBub3QgYXJncyBvciBhcmdzWzBdLnN0YXJ0c3dpdGgo
>> "!B64TMP!" echo Ii0tIik6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3ZWJfbW9uaXRvcl9nZXQucHkgPGlkPiBbLS1q
>> "!B64TMP!" echo c29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgogICAgbW9uaXRvcl9pZCA9
>> "!B64TMP!" echo IGFyZ3NbMF0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBhcmdzWzE6XQoKICAgIHRyeToKICAg
>> "!B64TMP!" echo ICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL21vbml0b3IvIiArIHN0cihtb25pdG9yX2lkKSwgbWV0
>> "!B64TMP!" echo aG9kPSJHRVQiKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIk1P
>> "!B64TMP!" echo TklUT1IgR0VUIEZBSUxFRCBmb3Ige21vbml0b3JfaWR9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIp
>> "!B64TMP!" echo CiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0
>> "!B64TMP!" echo ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNv
>> "!B64TMP!" echo bi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQoanNvbi5kdW1wcyhkYXRh
>> "!B64TMP!" echo LCBpbmRlbnQ9MikpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAg
>> "!B64TMP!" echo ICBzeXMuZXhpdChtYWluKCkpCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_monitor_get.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_monitor_update.py ---
set "B64TMP=%TEMP%\LSR3278219953.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJQYXRjaCBhbiBleGlzdGluZyBGaXJlY3Jhd2wgbW9u
>> "!B64TMP!" echo aXRvciBieSBJRCAodGhlIGZpcmVjcmF3bF9tb25pdG9yX3VwZGF0ZQpNQ1AgdG9vbCk6IGNoYW5n
>> "!B64TMP!" echo ZSBpdHMgbmFtZSwgYWN0aXZlL3BhdXNlZCBzdGF0dXMsIHNjaGVkdWxlLCB0YXJnZXRzLCBnb2Fs
>> "!B64TMP!" echo LApqdWRnaW5nLCB3ZWJob29rLCBub3RpZmljYXRpb25zLCBvciByZXRlbnRpb24g4oCUIHRoZXNl
>> "!B64TMP!" echo IGNoYW5nZXMgYWZmZWN0IGZ1dHVyZQpzY2hlZHVsZWQgY2hlY2tzLgoKVXNhZ2U6CiAgICBweXRo
>> "!B64TMP!" echo b24gd2ViX21vbml0b3JfdXBkYXRlLnB5IDxpZD4gKC0tYm9keSAney4uLn0nIHwgLS1ib2R5LWZp
>> "!B64TMP!" echo bGUgcGF0Y2guanNvbikKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFstLWpzb25d
>> "!B64TMP!" echo CgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUg
>> "!B64TMP!" echo KERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBh
>> "!B64TMP!" echo dXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2su
>> "!B64TMP!" echo cHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJl
>> "!B64TMP!" echo cwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3
>> "!B64TMP!" echo aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2su
>> "!B64TMP!" echo cHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpgLS1ib2R5YCBpcyB0aGUgcGF0Y2gg
>> "!B64TMP!" echo YXMgSlNPTiAoc2FtZSBvYmplY3QgdGhlIE1DUCB0b29sJ3MgYGJvZHlgIHBhcmFtZXRlcgp0YWtl
>> "!B64TMP!" echo cyk7IGAtLWJvZHktZmlsZWAgcmVhZHMgaXQgZnJvbSBhIGZpbGUgaW5zdGVhZC4gUHJpbnRzIHRo
>> "!B64TMP!" echo ZSB1cGRhdGVkCm1vbml0b3IgYXMgcHJldHR5IEpTT047IGAtLWpzb25gIHByaW50cyB0aGUgcmF3
>> "!B64TMP!" echo IEFQSSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFD
>> "!B64TMP!" echo Q09VTlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJ
>> "!B64TMP!" echo X0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9y
>> "!B64TMP!" echo IHRoZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhl
>> "!B64TMP!" echo bS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQo
>> "!B64TMP!" echo MCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmly
>> "!B64TMP!" echo ZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxm
>> "!B64TMP!" echo LWhlYWwKaW1wb3J0IHdlYl9tb25pdG9yX2NyZWF0ZSAgIyBzaWJsaW5nOiBzaGFyZWQgLS1ib2R5
>> "!B64TMP!" echo IC8gLS1ib2R5LWZpbGUgcmVhZGluZwoKRU5EUE9JTlQgPSBmYy51cmwoIi92MS9tb25pdG9yIikK
>> "!B64TMP!" echo CgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBh
>> "!B64TMP!" echo cmdzIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdl
>> "!B64TMP!" echo Yl9tb25pdG9yX3VwZGF0ZS5weSA8aWQ+ICgtLWJvZHkgJ3suLi59JyB8ICIKICAgICAgICAgICAg
>> "!B64TMP!" echo ICAiLS1ib2R5LWZpbGUgcGF0Y2guanNvbikgWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAg
>> "!B64TMP!" echo ICAgICAgcmV0dXJuIDIKICAgIG1vbml0b3JfaWQgPSBhcmdzWzBdCiAgICBhc19qc29uID0gIi0t
>> "!B64TMP!" echo anNvbiIgaW4gYXJncwogICAgYm9keSwgZXJyID0gd2ViX21vbml0b3JfY3JlYXRlLnJlYWRfYm9k
>> "!B64TMP!" echo eV9hcmcoYXJncykKICAgIGlmIGVycjoKICAgICAgICBwcmludChlcnIsIGZpbGU9c3lzLnN0ZGVy
>> "!B64TMP!" echo cikKICAgICAgICByZXR1cm4gMgoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3Yx
>> "!B64TMP!" echo L21vbml0b3IvIiArIHN0cihtb25pdG9yX2lkKSwgbWV0aG9kPSJQQVRDSCIsCiAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgYm9keT1ib2R5KQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAg
>> "!B64TMP!" echo ICBwcmludChmIk1PTklUT1IgVVBEQVRFIEZBSUxFRCBmb3Ige21vbml0b3JfaWR9OiB7ZX0iLCBm
>> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhp
>> "!B64TMP!" echo bnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAg
>> "!B64TMP!" echo ICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQo
>> "!B64TMP!" echo anNvbi5kdW1wcyhkYXRhLCBpbmRlbnQ9MikpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09
>> "!B64TMP!" echo ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_monitor_update.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_monitor_delete.py ---
set "B64TMP=%TEMP%\LSR3841707965.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJQZXJtYW5lbnRseSBkZWxldGUgYSBGaXJlY3Jhd2wg
>> "!B64TMP!" echo bW9uaXRvciBieSBJRCBhbmQgc3RvcCBpdHMgZnV0dXJlIHNjaGVkdWxlCih0aGUgZmlyZWNyYXds
>> "!B64TMP!" echo X21vbml0b3JfZGVsZXRlIE1DUCB0b29sKS4gVGhpcyBjYW5ub3QgYmUgdW5kb25lLgoKVXNhZ2U6
>> "!B64TMP!" echo CiAgICBweXRob24gd2ViX21vbml0b3JfZGVsZXRlLnB5IDxpZD4gWy0tanNvbl0KClNlbGYtaGVh
>> "!B64TMP!" echo bGluZzogaWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVu
>> "!B64TMP!" echo Z2luZSBvciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2Fs
>> "!B64TMP!" echo bHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5i
>> "!B64TMP!" echo YXQpIGFuZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVzCnNlbGYtaGVh
>> "!B64TMP!" echo bCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdpdGggYSBzaG9y
>> "!B64TMP!" echo dCBiYWNrb2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5weSBmaXJzdCDi
>> "!B64TMP!" echo gJQganVzdCBydW4gdGhlIHNjcmlwdC4KClByaW50cyBhIGNvbmZpcm1hdGlvbiAocGx1cyB0aGUg
>> "!B64TMP!" echo QVBJJ3MgcmVzcG9uc2UgYm9keSB3aGVuIG9uZSBpcyByZXR1cm5lZCkuCmAtLWpzb25gIHByaW50
>> "!B64TMP!" echo cyB0aGUgcmF3IEFQSSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmly
>> "!B64TMP!" echo ZWNyYXdsIEFDQ09VTlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJF
>> "!B64TMP!" echo Q1JBV0xfQVBJX0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3
>> "!B64TMP!" echo bC5kZXYgZm9yIHRoZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBl
>> "!B64TMP!" echo eHBvc2UgdGhlbS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0
>> "!B64TMP!" echo aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQpp
>> "!B64TMP!" echo bXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGll
>> "!B64TMP!" echo bnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVmIG1h
>> "!B64TMP!" echo aW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBpZiBub3QgYXJncyBvciBh
>> "!B64TMP!" echo cmdzWzBdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3ZWJfbW9uaXRv
>> "!B64TMP!" echo cl9kZWxldGUucHkgPGlkPiBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1
>> "!B64TMP!" echo cm4gMgogICAgbW9uaXRvcl9pZCA9IGFyZ3NbMF0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBh
>> "!B64TMP!" echo cmdzWzE6XQoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL21vbml0b3IvIiAr
>> "!B64TMP!" echo IHN0cihtb25pdG9yX2lkKSwgbWV0aG9kPSJERUxFVEUiKQogICAgZXhjZXB0IGZjLkZjRXJyb3Ig
>> "!B64TMP!" echo YXMgZToKICAgICAgICBwcmludChmIk1PTklUT1IgREVMRVRFIEZBSUxFRCBmb3Ige21vbml0b3Jf
>> "!B64TMP!" echo aWR9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAg
>> "!B64TMP!" echo ICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlm
>> "!B64TMP!" echo IGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4g
>> "!B64TMP!" echo MAogICAgcHJpbnQoZiJNb25pdG9yIHttb25pdG9yX2lkfSBkZWxldGVkLiIpCiAgICBpZiBkYXRh
>> "!B64TMP!" echo OgogICAgICAgIHByaW50KGpzb24uZHVtcHMoZGF0YSwgaW5kZW50PTIpKQogICAgcmV0dXJuIDAK
>> "!B64TMP!" echo CgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_monitor_delete.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_monitor_run.py ---
set "B64TMP=%TEMP%\LSR1028558844.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJRdWV1ZSBhbiBpbW1lZGlhdGUgY2hlY2sgZm9yIGEg
>> "!B64TMP!" echo RmlyZWNyYXdsIG1vbml0b3IsIG91dHNpZGUgaXRzIG5vcm1hbApzY2hlZHVsZSAodGhlIGZpcmVj
>> "!B64TMP!" echo cmF3bF9tb25pdG9yX3J1biBNQ1AgdG9vbCkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJfbW9uaXRv
>> "!B64TMP!" echo cl9ydW4ucHkgPGlkPiBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNo
>> "!B64TMP!" echo IHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFy
>> "!B64TMP!" echo ZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUg
>> "!B64TMP!" echo bG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVl
>> "!B64TMP!" echo c3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4
>> "!B64TMP!" echo IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVl
>> "!B64TMP!" echo ZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoK
>> "!B64TMP!" echo UHJpbnRzIHRoZSBxdWV1ZWQgY2hlY2sgYXMgcHJldHR5IEpTT04uIGAtLWpzb25gIHByaW50cyB0
>> "!B64TMP!" echo aGUgcmF3IEFQSSByZXNwb25zZQppbnN0ZWFkLiBGb2xsb3cgdGhlIGNoZWNrIHdpdGggd2ViX21v
>> "!B64TMP!" echo bml0b3JfY2hlY2tzLnB5IC8gd2ViX21vbml0b3JfY2hlY2sucHkuCgpOT1RFOiBtb25pdG9ycyBh
>> "!B64TMP!" echo cmUgYSBGaXJlY3Jhd2wgQUNDT1VOVCBmZWF0dXJlIOKAlCB0aGV5IG5lZWQgYW4gQVBJIGtleSAo
>> "!B64TMP!" echo c2V0CkZJUkVDUkFXTF9BUElfS0VZLCBhbmQgRklSRUNSQVdMX0FQSV9VUkw9aHR0cHM6Ly9hcGku
>> "!B64TMP!" echo ZmlyZWNyYXdsLmRldiBmb3IgdGhlCmNsb3VkIEFQSSk7IHRoZSBzZWxmLWhvc3RlZCBzdGFjayBt
>> "!B64TMP!" echo YXkgbm90IGV4cG9zZSB0aGVtLgoiIiIKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzeXMK
>> "!B64TMP!" echo CnN5cy5wYXRoLmluc2VydCgwLCBvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmls
>> "!B64TMP!" echo ZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xfYXBpIGFzIGZjICAjIHNpYmxpbmc6IEZpcmVjcmF3bCBI
>> "!B64TMP!" echo VFRQIGNsaWVudCArIHNlbGYtaGVhbAoKRU5EUE9JTlQgPSBmYy51cmwoIi92MS9tb25pdG9yIikK
>> "!B64TMP!" echo CgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBh
>> "!B64TMP!" echo cmdzIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdl
>> "!B64TMP!" echo Yl9tb25pdG9yX3J1bi5weSA8aWQ+IFstLWpzb25dIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAg
>> "!B64TMP!" echo IHJldHVybiAyCiAgICBtb25pdG9yX2lkID0gYXJnc1swXQogICAgYXNfanNvbiA9ICItLWpzb24i
>> "!B64TMP!" echo IGluIGFyZ3NbMTpdCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIvdjEvbW9uaXRv
>> "!B64TMP!" echo ci8iICsgc3RyKG1vbml0b3JfaWQpICsgIi9ydW4iLAogICAgICAgICAgICAgICAgICAgICAgIG1l
>> "!B64TMP!" echo dGhvZD0iUE9TVCIpCiAgICBleGNlcHQgZmMuRmNFcnJvciBhcyBlOgogICAgICAgIHByaW50KGYi
>> "!B64TMP!" echo TU9OSVRPUiBSVU4gRkFJTEVEIGZvciB7bW9uaXRvcl9pZH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVy
>> "!B64TMP!" echo cikKICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMu
>> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChq
>> "!B64TMP!" echo c29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCiAgICBwcmludChqc29uLmR1bXBzKGRh
>> "!B64TMP!" echo dGEsIGluZGVudD0yKSkKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoK
>> "!B64TMP!" echo ICAgIHN5cy5leGl0KG1haW4oKSkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_monitor_run.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_monitor_checks.py ---
set "B64TMP=%TEMP%\LSR3483113851.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJMaXN0IHRoZSBoaXN0b3JpY2FsIGNoZWNrcyBvZiBh
>> "!B64TMP!" echo IEZpcmVjcmF3bCBtb25pdG9yICh0aGUKZmlyZWNyYXdsX21vbml0b3JfY2hlY2tzIE1DUCB0b29s
>> "!B64TMP!" echo KSwgb3B0aW9uYWxseSBmaWx0ZXJlZCBieSBzdGF0dXMgYW5kCnBhZ2luYXRlZC4KClVzYWdlOgog
>> "!B64TMP!" echo ICAgcHl0aG9uIHdlYl9tb25pdG9yX2NoZWNrcy5weSA8aWQ+IFstLXN0YXR1cyBxdWV1ZWR8cnVu
>> "!B64TMP!" echo bmluZ3xjb21wbGV0ZWR8ZmFpbGVkfHBhcnRpYWxdCiAgICAgICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgIFstLWxpbWl0IE5dIFstLW9mZnNldCBOXSBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBp
>> "!B64TMP!" echo ZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9y
>> "!B64TMP!" echo IHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFy
>> "!B64TMP!" echo dHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5k
>> "!B64TMP!" echo IHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7
>> "!B64TMP!" echo IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tv
>> "!B64TMP!" echo ZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0
>> "!B64TMP!" echo IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIG9uZSBsaW5lIHBlciBjaGVjazogYE4uIDxjaGVja0lk
>> "!B64TMP!" echo PiA8c3RhdHVzPiA8Y3JlYXRlZEF0PmAuIGAtLWpzb25gCnByaW50cyB0aGUgcmF3IEFQSSByZXNw
>> "!B64TMP!" echo b25zZSBpbnN0ZWFkLiBSZWFkIG9uZSBjaGVjaydzIHBhZ2UtbGV2ZWwgcmVzdWx0cwp3aXRoIHdl
>> "!B64TMP!" echo Yl9tb25pdG9yX2NoZWNrLnB5LgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFDQ09V
>> "!B64TMP!" echo TlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJX0tF
>> "!B64TMP!" echo WSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yIHRo
>> "!B64TMP!" echo ZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4K
>> "!B64TMP!" echo IiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwg
>> "!B64TMP!" echo b3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNy
>> "!B64TMP!" echo YXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhl
>> "!B64TMP!" echo YWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgpTVEFUVVNFUyA9ICgicXVldWVk
>> "!B64TMP!" echo IiwgInJ1bm5pbmciLCAiY29tcGxldGVkIiwgImZhaWxlZCIsICJwYXJ0aWFsIikKCgpkZWYgbWFp
>> "!B64TMP!" echo bigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBhcmdzIG9yIGFy
>> "!B64TMP!" echo Z3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdlYl9tb25pdG9y
>> "!B64TMP!" echo X2NoZWNrcy5weSA8aWQ+ICIKICAgICAgICAgICAgICAiWy0tc3RhdHVzIHF1ZXVlZHxydW5uaW5n
>> "!B64TMP!" echo fGNvbXBsZXRlZHxmYWlsZWR8cGFydGlhbF0gIgogICAgICAgICAgICAgICJbLS1saW1pdCBOXSBb
>> "!B64TMP!" echo LS1vZmZzZXQgTl0gWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIK
>> "!B64TMP!" echo ICAgIG1vbml0b3JfaWQgPSBhcmdzWzBdCiAgICBzdGF0dXMsIGxpbWl0LCBvZmZzZXQsIGFzX2pz
>> "!B64TMP!" echo b24gPSBOb25lLCBOb25lLCBOb25lLCBGYWxzZQogICAgaSA9IDEKICAgIHdoaWxlIGkgPCBsZW4o
>> "!B64TMP!" echo YXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAgICBpZiBhID09ICItLXN0YXR1cyIgYW5k
>> "!B64TMP!" echo IGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgc3RhdHVz
>> "!B64TMP!" echo ID0gYXJnc1tpXQogICAgICAgICAgICBpZiBzdGF0dXMgbm90IGluIFNUQVRVU0VTOgogICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgcHJpbnQoZiJpbnZhbGlkIC0tc3RhdHVzOiB7c3RhdHVzfSAiCiAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICBmIihvbmUgb2YgeycsICcuam9pbihTVEFUVVNFUyl9KSIsIGZpbGU9c3lzLnN0
>> "!B64TMP!" echo ZGVycikKICAgICAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLWxpbWl0
>> "!B64TMP!" echo IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICB0
>> "!B64TMP!" echo cnk6CiAgICAgICAgICAgICAgICBsaW1pdCA9IGludChhcmdzW2ldKQogICAgICAgICAgICBleGNl
>> "!B64TMP!" echo cHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgICAgIHByaW50KGYiaW52YWxpZCAtLWxpbWl0OiB7
>> "!B64TMP!" echo YXJnc1tpXX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgICAgICByZXR1cm4gMgogICAg
>> "!B64TMP!" echo ICAgIGVsaWYgYSA9PSAiLS1vZmZzZXQiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAg
>> "!B64TMP!" echo ICAgaSArPSAxCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIG9mZnNldCA9IGludChh
>> "!B64TMP!" echo cmdzW2ldKQogICAgICAgICAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgICAgIHBy
>> "!B64TMP!" echo aW50KGYiaW52YWxpZCAtLW9mZnNldDoge2FyZ3NbaV19IiwgZmlsZT1zeXMuc3RkZXJyKQogICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tanNvbiI6CiAgICAgICAg
>> "!B64TMP!" echo ICAgIGFzX2pzb24gPSBUcnVlCiAgICAgICAgZWxpZiBhLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAg
>> "!B64TMP!" echo ICAgICAgIHByaW50KGYidW5rbm93biBvcHRpb246IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
>> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbHNlOgogICAgICAgICAgICBwcmludChmInVuZXhw
>> "!B64TMP!" echo ZWN0ZWQgYXJndW1lbnQ6IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJu
>> "!B64TMP!" echo IDIKICAgICAgICBpICs9IDEKCiAgICBxdWVyeSA9IHt9CiAgICBpZiBzdGF0dXMgaXMgbm90IE5v
>> "!B64TMP!" echo bmU6CiAgICAgICAgcXVlcnlbInN0YXR1cyJdID0gc3RhdHVzCiAgICBpZiBsaW1pdCBpcyBub3Qg
>> "!B64TMP!" echo Tm9uZToKICAgICAgICBxdWVyeVsibGltaXQiXSA9IGxpbWl0CiAgICBpZiBvZmZzZXQgaXMgbm90
>> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgcXVlcnlbIm9mZnNldCJdID0gb2Zmc2V0CgogICAgdHJ5OgogICAgICAg
>> "!B64TMP!" echo IGRhdGEgPSBmYy5jYWxsKCIvdjEvbW9uaXRvci8iICsgc3RyKG1vbml0b3JfaWQpICsgIi9jaGVj
>> "!B64TMP!" echo a3MiLAogICAgICAgICAgICAgICAgICAgICAgIG1ldGhvZD0iR0VUIiwgcXVlcnk9cXVlcnkpCiAg
>> "!B64TMP!" echo ICBleGNlcHQgZmMuRmNFcnJvciBhcyBlOgogICAgICAgIHByaW50KGYiTU9OSVRPUiBDSEVDS1Mg
>> "!B64TMP!" echo RkFJTEVEIGZvciB7bW9uaXRvcl9pZH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBp
>> "!B64TMP!" echo ZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMuc3RkZXJyKQogICAg
>> "!B64TMP!" echo ICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChqc29uLmR1bXBzKGRh
>> "!B64TMP!" echo dGEpKQogICAgICAgIHJldHVybiAwCgogICAgY2hlY2tzID0gZGF0YS5nZXQoImNoZWNrcyIpCiAg
>> "!B64TMP!" echo ICBpZiBub3QgaXNpbnN0YW5jZShjaGVja3MsIGxpc3QpOgogICAgICAgIGNoZWNrcyA9IGRhdGEu
>> "!B64TMP!" echo Z2V0KCJkYXRhIikKICAgIGlmIG5vdCBpc2luc3RhbmNlKGNoZWNrcywgbGlzdCk6CiAgICAgICAg
>> "!B64TMP!" echo Y2hlY2tzID0gZGF0YSBpZiBpc2luc3RhbmNlKGRhdGEsIGxpc3QpIGVsc2UgW10KICAgIGlmIG5v
>> "!B64TMP!" echo dCBjaGVja3M6CiAgICAgICAgcHJpbnQoIihubyBjaGVja3MpIikKICAgICAgICByZXR1cm4gMAog
>> "!B64TMP!" echo ICAgZm9yIG4sIGNoZWNrIGluIGVudW1lcmF0ZShjaGVja3MsIDEpOgogICAgICAgIGlmIG5vdCBp
>> "!B64TMP!" echo c2luc3RhbmNlKGNoZWNrLCBkaWN0KToKICAgICAgICAgICAgcHJpbnQoZiJ7bn0uIHtjaGVja30i
>> "!B64TMP!" echo KQogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGNpZCA9IGNoZWNrLmdldCgiaWQiKSBvciBj
>> "!B64TMP!" echo aGVjay5nZXQoImNoZWNrSWQiKSBvciAiPyIKICAgICAgICBjc3RhdHVzID0gY2hlY2suZ2V0KCJz
>> "!B64TMP!" echo dGF0dXMiKSBvciAiPyIKICAgICAgICB3aGVuID0gKGNoZWNrLmdldCgiY3JlYXRlZEF0Iikgb3Ig
>> "!B64TMP!" echo Y2hlY2suZ2V0KCJzdGFydGVkQXQiKQogICAgICAgICAgICAgICAgb3IgY2hlY2suZ2V0KCJjb21w
>> "!B64TMP!" echo bGV0ZWRBdCIpIG9yICIiKQogICAgICAgIHByaW50KGYie259LiB7Y2lkfSB7Y3N0YXR1c30ge3do
>> "!B64TMP!" echo ZW59Ii5yc3RyaXAoKSkKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoK
>> "!B64TMP!" echo ICAgIHN5cy5leGl0KG1haW4oKSkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_monitor_checks.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_monitor_check.py ---
set "B64TMP=%TEMP%\LSR275179508.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZXRyaWV2ZSBvbmUgRmlyZWNyYXdsIG1vbml0b3Ig
>> "!B64TMP!" echo Y2hlY2sgYW5kIGl0cyBwYWdlLWxldmVsIHJlc3VsdHMgKHRoZQpmaXJlY3Jhd2xfbW9uaXRvcl9j
>> "!B64TMP!" echo aGVjayBNQ1AgdG9vbCkuIFBhZ2VzIHJlcG9ydCBgc2FtZWAsIGBuZXdgLCBgY2hhbmdlZGAsCmBy
>> "!B64TMP!" echo ZW1vdmVkYCwgb3IgYGVycm9yYDsgZ29hbCBqdWRnaW5nIGFkZHMgYSBtZWFuaW5nZnVsLWNoYW5n
>> "!B64TMP!" echo ZSBkZWNpc2lvbi4KTWFya2Rvd24gdHJhY2tpbmcgcmV0dXJucyBhIHVuaWZpZWQgdGV4dCBkaWZm
>> "!B64TMP!" echo OyBKU09OIHRyYWNraW5nIHJldHVybnMgZmllbGQKcGF0aHMgd2l0aCBwcmV2aW91cy9jdXJyZW50
>> "!B64TMP!" echo IHZhbHVlcy4KClVzYWdlOgogICAgcHl0aG9uIHdlYl9tb25pdG9yX2NoZWNrLnB5IDxpZD4gPGNo
>> "!B64TMP!" echo ZWNrSWQ+IFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sg
>> "!B64TMP!" echo aXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24p
>> "!B64TMP!" echo LCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwph
>> "!B64TMP!" echo cyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29u
>> "!B64TMP!" echo bmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2Vy
>> "!B64TMP!" echo cyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1
>> "!B64TMP!" echo biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpQcmludHMg
>> "!B64TMP!" echo dGhlIGNoZWNrIChjb25maWd1cmF0aW9uLCBwYWdlIHJlc3VsdHMsIGRpZmZzKSBhcyBwcmV0dHkg
>> "!B64TMP!" echo SlNPTi4KYC0tanNvbmAgcHJpbnRzIHRoZSByYXcgQVBJIHJlc3BvbnNlIGluc3RlYWQuCgpOT1RF
>> "!B64TMP!" echo OiBtb25pdG9ycyBhcmUgYSBGaXJlY3Jhd2wgQUNDT1VOVCBmZWF0dXJlIOKAlCB0aGV5IG5lZWQg
>> "!B64TMP!" echo YW4gQVBJIGtleSAoc2V0CkZJUkVDUkFXTF9BUElfS0VZLCBhbmQgRklSRUNSQVdMX0FQSV9VUkw9
>> "!B64TMP!" echo aHR0cHM6Ly9hcGkuZmlyZWNyYXdsLmRldiBmb3IgdGhlCmNsb3VkIEFQSSk7IHRoZSBzZWxmLWhv
>> "!B64TMP!" echo c3RlZCBzdGFjayBtYXkgbm90IGV4cG9zZSB0aGVtLgoiIiIKaW1wb3J0IGpzb24KaW1wb3J0IG9z
>> "!B64TMP!" echo CmltcG9ydCBzeXMKCnN5cy5wYXRoLmluc2VydCgwLCBvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5h
>> "!B64TMP!" echo YnNwYXRoKF9fZmlsZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xfYXBpIGFzIGZjICAjIHNpYmxpbmc6
>> "!B64TMP!" echo IEZpcmVjcmF3bCBIVFRQIGNsaWVudCArIHNlbGYtaGVhbAoKRU5EUE9JTlQgPSBmYy51cmwoIi92
>> "!B64TMP!" echo MS9tb25pdG9yIikKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBbYSBmb3IgYSBpbiBz
>> "!B64TMP!" echo eXMuYXJndlsxOl0gaWYgYSAhPSAiLS1qc29uIl0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBz
>> "!B64TMP!" echo eXMuYXJndlsxOl0KICAgIGlmIGxlbihhcmdzKSAhPSAyIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgi
>> "!B64TMP!" echo LS0iKSBvciBhcmdzWzFdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3
>> "!B64TMP!" echo ZWJfbW9uaXRvcl9jaGVjay5weSA8aWQ+IDxjaGVja0lkPiBbLS1qc29uXSIsCiAgICAgICAgICAg
>> "!B64TMP!" echo ICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCiAgICBtb25pdG9yX2lkLCBjaGVj
>> "!B64TMP!" echo a19pZCA9IGFyZ3MKCiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNhbGwoIi92MS9tb25pdG9y
>> "!B64TMP!" echo LyIgKyBzdHIobW9uaXRvcl9pZCkgKyAiL2NoZWNrcy8iCiAgICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo KyBzdHIoY2hlY2tfaWQpLCBtZXRob2Q9IkdFVCIpCiAgICBleGNlcHQgZmMuRmNFcnJvciBhcyBl
>> "!B64TMP!" echo OgogICAgICAgIHByaW50KGYiTU9OSVRPUiBDSEVDSyBGQUlMRUQgZm9yIHttb25pdG9yX2lkfS97
>> "!B64TMP!" echo Y2hlY2tfaWR9OiB7ZX0iLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBp
>> "!B64TMP!" echo ZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMuc3RkZXJyKQogICAg
>> "!B64TMP!" echo ICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChqc29uLmR1bXBzKGRh
>> "!B64TMP!" echo dGEpKQogICAgICAgIHJldHVybiAwCiAgICBwcmludChqc29uLmR1bXBzKGRhdGEsIGluZGVudD0y
>> "!B64TMP!" echo KSkKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0
>> "!B64TMP!" echo KG1haW4oKSkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_monitor_check.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_research_search.py ---
set "B64TMP=%TEMP%\LSR2099142635.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggcmVzZWFyY2ggcGFwZXJzIHZpYSB0aGUg
>> "!B64TMP!" echo RmlyZWNyYXdsIHJlc2VhcmNoIGluZGV4ICh0aGUKZmlyZWNyYXdsX3Jlc2VhcmNoX3NlYXJjaF9w
>> "!B64TMP!" echo YXBlcnMgTUNQIHRvb2wpOiBwYXBlciBtZXRhZGF0YSBhbmQgYWJzdHJhY3RzCmFjcm9zcyBiaW9t
>> "!B64TMP!" echo ZWRpY2FsLCBsaWZlLXNjaWVuY2UsIGFuZCBjbGluaWNhbCBsaXRlcmF0dXJlIChQdWJNZWQsIGJp
>> "!B64TMP!" echo b1J4aXYsCm1lZFJ4aXYpIGFsb25nc2lkZSBhclhpdiBhbmQgb3RoZXIgc2NpZW50aWZpYyBzb3Vy
>> "!B64TMP!" echo Y2VzLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX3Jlc2VhcmNoX3NlYXJjaC5weSAiPHF1ZXJ5PiIg
>> "!B64TMP!" echo Wy0tanNvbl0KClNlbGYtaGVhbGluZzogaWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJl
>> "!B64TMP!" echo YWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMg
>> "!B64TMP!" echo c2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3Vy
>> "!B64TMP!" echo ZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9u
>> "!B64TMP!" echo IGZhaWx1cmVzCnNlbGYtaGVhbCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSBy
>> "!B64TMP!" echo ZXRyaWVkIHdpdGggYSBzaG9ydCBiYWNrb2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3Vy
>> "!B64TMP!" echo ZV9zdGFjay5weSBmaXJzdCDigJQganVzdCBydW4gdGhlIHNjcmlwdC4KClByaW50cyB0aGUgcmFu
>> "!B64TMP!" echo a2VkIHBhcGVycyBleGFjdGx5IGxpa2UgdGhlIE1DUCB0b29sIGRvZXMg4oCUIGZvciBlYWNoIHBh
>> "!B64TMP!" echo cGVyOgoKICAgICMjIFtwYXBlcklkXSB0aXRsZQogICAgQXV0aG9yczogbmFtZTsgbmFtZTsgK04g
>> "!B64TMP!" echo bW9yZQogICAgYWJzdHJhY3QgKHVwIHRvIDYwMCBjaGFycykKClNldmVyYWwgZGlzdGluY3QgZnJh
>> "!B64TMP!" echo bWluZ3Mgb2YgdGhlIHNhbWUgcXVlc3Rpb24gc3VyZmFjZSBkaWZmZXJlbnQgcGFwZXJzLgpJbnNw
>> "!B64TMP!" echo ZWN0IG9uZSBwYXBlciB3aXRoIHdlYl9yZXNlYXJjaF9pbnNwZWN0LnB5LiBgLS1qc29uYCBwcmlu
>> "!B64TMP!" echo dHMgdGhlIHJhdyBBUEkKcmVzcG9uc2UgaW5zdGVhZC4KCk5PVEU6IHJlc2VhcmNoIHRvb2xzIG5l
>> "!B64TMP!" echo ZWQgYSBGaXJlY3Jhd2wgYWNjb3VudCB3aXRoIHJlc2VhcmNoIHBlcm1pc3Npb25zCihzZXQgRklS
>> "!B64TMP!" echo RUNSQVdMX0FQSV9LRVksIGFuZCBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczovL2FwaS5maXJlY3Jh
>> "!B64TMP!" echo d2wuZGV2IGZvcgp0aGUgY2xvdWQgQVBJKTsgdGhlIHNlbGYtaG9zdGVkIHN0YWNrIG1heSBub3Qg
>> "!B64TMP!" echo ZXhwb3NlIHRoZW0uCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lzLnBh
>> "!B64TMP!" echo dGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkK
>> "!B64TMP!" echo aW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xp
>> "!B64TMP!" echo ZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL3Jlc2VhcmNoL3NlYXJjaC9w
>> "!B64TMP!" echo YXBlcnMiKQoKTUFYX0FVVEhPUlMgPSAxNQpNQVhfQUJTVFJBQ1RfQ0hBUlMgPSA2MDAKTUFYX0FG
>> "!B64TMP!" echo RklMX0NIQVJTID0gNjAKTUFYX0FVVEhPUlNfTElORV9DSEFSUyA9IDQwMAoKCmRlZiBkaXNwbGF5
>> "!B64TMP!" echo X2lkKHBhcGVyKToKICAgIHJldHVybiBwYXBlci5nZXQoInByaW1hcnlJZCIpIG9yIHBhcGVyLmdl
>> "!B64TMP!" echo dCgicGFwZXJJZCIpIG9yICJtaXNzaW5nLXByaW1hcnktaWQiCgoKZGVmIGZtdF9hdXRob3JzKGF1
>> "!B64TMP!" echo dGhvcnMpOgogICAgIiIiYEF1dGhvcnM6IGE7IGIgKGFmZmlsaWF0aW9uKTsgK04gbW9yZWAgb3Ig
>> "!B64TMP!" echo Tm9uZSAobWlycm9ycyB0aGUgTUNQIHRvb2wpLiIiIgogICAgaWYgbm90IGF1dGhvcnM6CiAgICAg
>> "!B64TMP!" echo ICAgcmV0dXJuIE5vbmUKICAgIGlmIGlzaW5zdGFuY2UoYXV0aG9ycywgc3RyKToKICAgICAgICBu
>> "!B64TMP!" echo YW1lcyA9IFtzLnN0cmlwKCkgZm9yIHMgaW4gYXV0aG9ycy5zcGxpdCgiLCIpIGlmIHMuc3RyaXAo
>> "!B64TMP!" echo KV0KICAgICAgICBpZiBub3QgbmFtZXM6CiAgICAgICAgICAgIHJldHVybiBOb25lCiAgICAgICAg
>> "!B64TMP!" echo dG90YWwsIHNob3duID0gbGVuKG5hbWVzKSwgbmFtZXNbOk1BWF9BVVRIT1JTXQogICAgZWxzZToK
>> "!B64TMP!" echo ICAgICAgICBpZiBub3QgaXNpbnN0YW5jZShhdXRob3JzLCBsaXN0KSBvciBub3QgYXV0aG9yczoK
>> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgICAgICB0b3RhbCA9IGxlbihhdXRob3JzKQogICAg
>> "!B64TMP!" echo ICAgIHNob3duID0gW10KICAgICAgICBmb3IgYSBpbiBhdXRob3JzWzpNQVhfQVVUSE9SU106CiAg
>> "!B64TMP!" echo ICAgICAgICAgIGlmIGlzaW5zdGFuY2UoYSwgZGljdCk6CiAgICAgICAgICAgICAgICBhZmYgPSAo
>> "!B64TMP!" echo YS5nZXQoImFmZmlsaWF0aW9uIikgb3IgIiIpLnN0cmlwKCkKICAgICAgICAgICAgICAgIG5hbWUg
>> "!B64TMP!" echo PSBhLmdldCgibmFtZSIpIG9yICI/IgogICAgICAgICAgICAgICAgc2hvd24uYXBwZW5kKCJ7fSAo
>> "!B64TMP!" echo e30pIi5mb3JtYXQobmFtZSwgYWZmWzpNQVhfQUZGSUxfQ0hBUlNdKQogICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgIGlmIGFmZiBlbHNlIG5hbWUpCiAgICAgICAgICAgIGVsc2U6CiAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICBzaG93bi5hcHBlbmQoc3RyKGEpKQogICAgZXh0cmEgPSAiOyAre30gbW9yZSIuZm9y
>> "!B64TMP!" echo bWF0KHRvdGFsIC0gTUFYX0FVVEhPUlMpIGlmIHRvdGFsID4gTUFYX0FVVEhPUlMgXAogICAgICAg
>> "!B64TMP!" echo IGVsc2UgIiIKICAgIHJldHVybiAoIkF1dGhvcnM6ICIgKyAiOyAiLmpvaW4oc2hvd24pICsgZXh0
>> "!B64TMP!" echo cmEpWzpNQVhfQVVUSE9SU19MSU5FX0NIQVJTXQoKCmRlZiBmbXRfaGl0cyhyZXN1bHRzKToKICAg
>> "!B64TMP!" echo ICIiIkZvcm1hdCByYW5rZWQgcGFwZXIgcmVzdWx0cyAobWlycm9ycyB0aGUgTUNQIHRvb2wncyBm
>> "!B64TMP!" echo b3JtYXR0ZXIpLiIiIgogICAgaWYgbm90IHJlc3VsdHM6CiAgICAgICAgcmV0dXJuICIobm8gcmVz
>> "!B64TMP!" echo dWx0cykiCiAgICBibG9ja3MgPSBbXQogICAgZm9yIHIgaW4gcmVzdWx0czoKICAgICAgICBpZiBu
>> "!B64TMP!" echo b3QgaXNpbnN0YW5jZShyLCBkaWN0KToKICAgICAgICAgICAgYmxvY2tzLmFwcGVuZChzdHIocikp
>> "!B64TMP!" echo CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgbGluZXMgPSBbIiMjIFt7fV0ge30iLmZvcm1h
>> "!B64TMP!" echo dChkaXNwbGF5X2lkKHIpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgci5n
>> "!B64TMP!" echo ZXQoInRpdGxlIikgb3IgIih1bnRpdGxlZCkiKV0KICAgICAgICBhdXRob3JzID0gZm10X2F1dGhv
>> "!B64TMP!" echo cnMoci5nZXQoImF1dGhvcnMiKSkKICAgICAgICBpZiBhdXRob3JzOgogICAgICAgICAgICBsaW5l
>> "!B64TMP!" echo cy5hcHBlbmQoYXV0aG9ycykKICAgICAgICBhYnN0cmFjdCA9IChyLmdldCgiYWJzdHJhY3QiKSBv
>> "!B64TMP!" echo ciAiKG5vIGFic3RyYWN0KSIpCiAgICAgICAgYWJzdHJhY3QgPSAiICIuam9pbihhYnN0cmFjdC5z
>> "!B64TMP!" echo cGxpdCgpKVs6TUFYX0FCU1RSQUNUX0NIQVJTXQogICAgICAgIGxpbmVzLmFwcGVuZChhYnN0cmFj
>> "!B64TMP!" echo dCkKICAgICAgICBibG9ja3MuYXBwZW5kKCJcbiIuam9pbihsaW5lcykpCiAgICByZXR1cm4gIlxu
>> "!B64TMP!" echo XG4iLmpvaW4oYmxvY2tzKQoKCmRlZiBleHRyYWN0X3Jlc3VsdHMoZGF0YSk6CiAgICAiIiJGaW5k
>> "!B64TMP!" echo IHRoZSBwYXBlci1yZXN1bHQgbGlzdCBpbiB0aGUgQVBJIHJlc3BvbnNlLiIiIgogICAgcmVzdWx0
>> "!B64TMP!" echo cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIikKICAgIGlmIGlzaW5zdGFuY2UocmVzdWx0cywgbGlzdCk6
>> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIHJlc3VsdHMKICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0YSIpCiAg
>> "!B64TMP!" echo ICBpZiBpc2luc3RhbmNlKHBheWxvYWQsIGRpY3QpIGFuZCBpc2luc3RhbmNlKHBheWxvYWQuZ2V0
>> "!B64TMP!" echo KCJyZXN1bHRzIiksIGxpc3QpOgogICAgICAgIHJldHVybiBwYXlsb2FkWyJyZXN1bHRzIl0KICAg
>> "!B64TMP!" echo IGlmIGlzaW5zdGFuY2UoZGF0YSwgbGlzdCk6CiAgICAgICAgcmV0dXJuIGRhdGEKICAgIHJldHVy
>> "!B64TMP!" echo biBbXQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IFthIGZvciBhIGluIHN5cy5hcmd2
>> "!B64TMP!" echo WzE6XSBpZiBhICE9ICItLWpzb24iXQogICAgYXNfanNvbiA9ICItLWpzb24iIGluIHN5cy5hcmd2
>> "!B64TMP!" echo WzE6XQogICAgcXVlcnkgPSAiICIuam9pbihhcmdzKS5zdHJpcCgpCiAgICBpZiBub3QgcXVlcnk6
>> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoJ3VzYWdlOiB3ZWJfcmVzZWFyY2hfc2VhcmNoLnB5ICI8cXVlcnk+IiBb
>> "!B64TMP!" echo LS1qc29uXScsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgoKICAgIHRyeToKICAg
>> "!B64TMP!" echo ICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL3Jlc2VhcmNoL3NlYXJjaC9wYXBlcnMiLCBtZXRob2Q9
>> "!B64TMP!" echo IlBPU1QiLAogICAgICAgICAgICAgICAgICAgICAgIGJvZHk9eyJxdWVyeSI6IHF1ZXJ5fSkKICAg
>> "!B64TMP!" echo IGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJSRVNFQVJDSCBTRUFSQ0gg
>> "!B64TMP!" echo RkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAg
>> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAg
>> "!B64TMP!" echo IGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1
>> "!B64TMP!" echo cm4gMAogICAgcHJpbnQoZm10X2hpdHMoZXh0cmFjdF9yZXN1bHRzKGRhdGEpKSkKICAgIHJldHVy
>> "!B64TMP!" echo biAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_research_search.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_research_inspect.py ---
set "B64TMP=%TEMP%\LSR1702833664.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJJbnNwZWN0IG9uZSByZXNlYXJjaCBwYXBlciB2aWEg
>> "!B64TMP!" echo dGhlIEZpcmVjcmF3bCByZXNlYXJjaCBpbmRleCAodGhlCmZpcmVjcmF3bF9yZXNlYXJjaF9pbnNw
>> "!B64TMP!" echo ZWN0X3BhcGVyIE1DUCB0b29sKTogY2Fub25pY2FsIG1ldGFkYXRhIGZvciBhIHBhcGVyCklEIHN1
>> "!B64TMP!" echo Y2ggYXMgYW4gYXJYaXYsIFBNQywgUE1JRCwgb3IgRE9JIGlkZW50aWZpZXIuCgpVc2FnZToKICAg
>> "!B64TMP!" echo IHB5dGhvbiB3ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSA8cGFwZXJJZD4gWy0tanNvbl0KCkV4YW1w
>> "!B64TMP!" echo bGVzOgogICAgcHl0aG9uIHdlYl9yZXNlYXJjaF9pbnNwZWN0LnB5IGFyeGl2OjE3MDYuMDM3NjIK
>> "!B64TMP!" echo ICAgIHB5dGhvbiB3ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSBkb2k6MTAuMTAxNi9qLm5ldW5ldC4y
>> "!B64TMP!" echo MDI1LjEwODA5NQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVu
>> "!B64TMP!" echo cmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhp
>> "!B64TMP!" echo cyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5z
>> "!B64TMP!" echo dXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rp
>> "!B64TMP!" echo b24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJl
>> "!B64TMP!" echo IHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5z
>> "!B64TMP!" echo dXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIHRoZSBw
>> "!B64TMP!" echo YXBlcidzIG1ldGFkYXRhIGV4YWN0bHkgbGlrZSB0aGUgTUNQIHRvb2wgZG9lczoKCiAgICAjIHRp
>> "!B64TMP!" echo dGxlCiAgICBQYXBlciBJRDogLi4uCiAgICBJRHM6IG5hbWVzcGFjZTp2YWx1ZSwgLi4uCiAgICBB
>> "!B64TMP!" echo dXRob3JzOiAuLi4KICAgIENhdGVnb3JpZXM6IC4uLgogICAgRGF0ZXM6IGNyZWF0ZWQgLi4uOyB1
>> "!B64TMP!" echo cGRhdGVkIC4uLgogICAgIyMgQWJzdHJhY3QKICAgIC4uLgoKRmluZCBwYXBlcnMgdG8gaW5zcGVj
>> "!B64TMP!" echo dCB3aXRoIHdlYl9yZXNlYXJjaF9zZWFyY2gucHkuIGAtLWpzb25gIHByaW50cyB0aGUgcmF3CkFQ
>> "!B64TMP!" echo SSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogcmVzZWFyY2ggdG9vbHMgbmVlZCBhIEZpcmVjcmF3
>> "!B64TMP!" echo bCBhY2NvdW50IHdpdGggcmVzZWFyY2ggcGVybWlzc2lvbnMKKHNldCBGSVJFQ1JBV0xfQVBJX0tF
>> "!B64TMP!" echo WSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yCnRo
>> "!B64TMP!" echo ZSBjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4K
>> "!B64TMP!" echo IiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCmltcG9ydCB1cmxsaWIucGFyc2UK
>> "!B64TMP!" echo CnN5cy5wYXRoLmluc2VydCgwLCBvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmls
>> "!B64TMP!" echo ZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xfYXBpIGFzIGZjICAjIHNpYmxpbmc6IEZpcmVjcmF3bCBI
>> "!B64TMP!" echo VFRQIGNsaWVudCArIHNlbGYtaGVhbAppbXBvcnQgd2ViX3Jlc2VhcmNoX3NlYXJjaCAgIyBzaWJs
>> "!B64TMP!" echo aW5nOiBzaGFyZWQgcGFwZXIgZm9ybWF0dGVycwoKRU5EUE9JTlQgPSBmYy51cmwoIi92MS9yZXNl
>> "!B64TMP!" echo YXJjaC9wYXBlcnMiKQoKCmRlZiBmbXRfcGFwZXJfbWV0YWRhdGEocGFwZXIpOgogICAgIiIiRm9y
>> "!B64TMP!" echo bWF0IG9uZSBwYXBlcidzIG1ldGFkYXRhIChtaXJyb3JzIHRoZSBNQ1AgdG9vbCdzIGZvcm1hdHRl
>> "!B64TMP!" echo cikuIiIiCiAgICBpZiBub3QgcGFwZXI6CiAgICAgICAgcmV0dXJuICIocGFwZXIgbm90IGZvdW5k
>> "!B64TMP!" echo KSIKICAgIGxpbmVzID0gWyIjICIgKyAocGFwZXIuZ2V0KCJ0aXRsZSIpIG9yICIodW50aXRsZWQp
>> "!B64TMP!" echo IiksICIiXQogICAgbGluZXMuYXBwZW5kKCJQYXBlciBJRDoge30iLmZvcm1hdChwYXBlci5nZXQo
>> "!B64TMP!" echo InBhcGVySWQiKSBvciAiPyIpKQogICAgaWRzID0gW10KICAgIGZvciBuYW1lc3BhY2UsIHZhbHVl
>> "!B64TMP!" echo cyBpbiAocGFwZXIuZ2V0KCJpZHMiKSBvciB7fSkuaXRlbXMoKToKICAgICAgICBpZiBpc2luc3Rh
>> "!B64TMP!" echo bmNlKHZhbHVlcywgbGlzdCk6CiAgICAgICAgICAgIGlkcy5leHRlbmQoInt9Ont9Ii5mb3JtYXQo
>> "!B64TMP!" echo bmFtZXNwYWNlLCB2KSBmb3IgdiBpbiB2YWx1ZXMpCiAgICAgICAgZWxpZiB2YWx1ZXMgaXMgbm90
>> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgICAgIGlkcy5hcHBlbmQoInt9Ont9Ii5mb3JtYXQobmFtZXNwYWNlLCB2
>> "!B64TMP!" echo YWx1ZXMpKQogICAgaWYgaWRzOgogICAgICAgIGxpbmVzLmFwcGVuZCgiSURzOiAiICsgIiwgIi5q
>> "!B64TMP!" echo b2luKGlkcykpCiAgICBhdXRob3JzID0gd2ViX3Jlc2VhcmNoX3NlYXJjaC5mbXRfYXV0aG9ycyhw
>> "!B64TMP!" echo YXBlci5nZXQoImF1dGhvcnMiKSkKICAgIGlmIGF1dGhvcnM6CiAgICAgICAgbGluZXMuYXBwZW5k
>> "!B64TMP!" echo KGF1dGhvcnMpCiAgICBjYXRlZ29yaWVzID0gcGFwZXIuZ2V0KCJjYXRlZ29yaWVzIikKICAgIGlm
>> "!B64TMP!" echo IGlzaW5zdGFuY2UoY2F0ZWdvcmllcywgbGlzdCkgYW5kIGNhdGVnb3JpZXM6CiAgICAgICAgbGlu
>> "!B64TMP!" echo ZXMuYXBwZW5kKCJDYXRlZ29yaWVzOiAiICsgIiwgIi5qb2luKHN0cihjKSBmb3IgYyBpbiBjYXRl
>> "!B64TMP!" echo Z29yaWVzKSkKICAgIGRhdGVzID0gW10KICAgIGlmIHBhcGVyLmdldCgiY3JlYXRlZERhdGUiKToK
>> "!B64TMP!" echo ICAgICAgICBkYXRlcy5hcHBlbmQoImNyZWF0ZWQgIiArIHN0cihwYXBlclsiY3JlYXRlZERhdGUi
>> "!B64TMP!" echo XSkpCiAgICBpZiBwYXBlci5nZXQoInVwZGF0ZURhdGUiKToKICAgICAgICBkYXRlcy5hcHBlbmQo
>> "!B64TMP!" echo InVwZGF0ZWQgIiArIHN0cihwYXBlclsidXBkYXRlRGF0ZSJdKSkKICAgIGlmIGRhdGVzOgogICAg
>> "!B64TMP!" echo ICAgIGxpbmVzLmFwcGVuZCgiRGF0ZXM6ICIgKyAiOyAiLmpvaW4oZGF0ZXMpKQogICAgbGluZXMu
>> "!B64TMP!" echo YXBwZW5kKCIiKQogICAgbGluZXMuYXBwZW5kKCIjIyBBYnN0cmFjdCIpCiAgICBsaW5lcy5hcHBl
>> "!B64TMP!" echo bmQoIiAiLmpvaW4oKHBhcGVyLmdldCgiYWJzdHJhY3QiKSBvciAiKG5vIGFic3RyYWN0KSIpLnNw
>> "!B64TMP!" echo bGl0KCkpKQogICAgcmV0dXJuICJcbiIuam9pbihsaW5lcykKCgpkZWYgZXh0cmFjdF9wYXBlcihk
>> "!B64TMP!" echo YXRhKToKICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5n
>> "!B64TMP!" echo ZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRhCiAgICBwYXBlciA9IHBheWxvYWQuZ2V0KCJwYXBl
>> "!B64TMP!" echo ciIpCiAgICBpZiBpc2luc3RhbmNlKHBhcGVyLCBkaWN0KToKICAgICAgICByZXR1cm4gcGFwZXIK
>> "!B64TMP!" echo ICAgIGlmIGlzaW5zdGFuY2UocGF5bG9hZCwgZGljdCkgYW5kIChwYXlsb2FkLmdldCgicGFwZXJJ
>> "!B64TMP!" echo ZCIpIG9yIHBheWxvYWQuZ2V0KCJ0aXRsZSIpKToKICAgICAgICByZXR1cm4gcGF5bG9hZAogICAg
>> "!B64TMP!" echo cmV0dXJuIE5vbmUKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBbYSBmb3IgYSBpbiBz
>> "!B64TMP!" echo eXMuYXJndlsxOl0gaWYgYSAhPSAiLS1qc29uIl0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBz
>> "!B64TMP!" echo eXMuYXJndlsxOl0KICAgIGlmIGxlbihhcmdzKSAhPSAxIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgi
>> "!B64TMP!" echo LS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdlYl9yZXNlYXJjaF9pbnNwZWN0LnB5IDxwYXBl
>> "!B64TMP!" echo cklkPiBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgogICAgcGFw
>> "!B64TMP!" echo ZXJfaWQgPSBhcmdzWzBdCgogICAgcGF0aCA9ICIvdjEvcmVzZWFyY2gvcGFwZXJzLyIgKyB1cmxs
>> "!B64TMP!" echo aWIucGFyc2UucXVvdGUocGFwZXJfaWQsIHNhZmU9IiIpCiAgICB0cnk6CiAgICAgICAgZGF0YSA9
>> "!B64TMP!" echo IGZjLmNhbGwocGF0aCwgbWV0aG9kPSJHRVQiKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToK
>> "!B64TMP!" echo ICAgICAgICBwcmludChmIlJFU0VBUkNIIElOU1BFQ1QgRkFJTEVEIGZvciB7cGFwZXJfaWR9OiB7
>> "!B64TMP!" echo ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmlu
>> "!B64TMP!" echo dChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pz
>> "!B64TMP!" echo b246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAg
>> "!B64TMP!" echo cHJpbnQoZm10X3BhcGVyX21ldGFkYXRhKGV4dHJhY3RfcGFwZXIoZGF0YSkpKQogICAgcmV0dXJu
>> "!B64TMP!" echo IDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_research_inspect.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_research_related.py ---
set "B64TMP=%TEMP%\LSR1267010878.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJGaW5kIHJlc2VhcmNoIHBhcGVycyByZWxhdGVkIHRv
>> "!B64TMP!" echo IHNlZWQgcGFwZXJzIHZpYSB0aGUgRmlyZWNyYXdsIGNpdGF0aW9uCmdyYXBoICh0aGUgZmlyZWNy
>> "!B64TMP!" echo YXdsX3Jlc2VhcmNoX3JlbGF0ZWRfcGFwZXJzIE1DUCB0b29sKS4KClVzYWdlOgogICAgcHl0aG9u
>> "!B64TMP!" echo IHdlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IDxzZWVkSWQ+IFtzZWVkSWQgLi4uXSAtLWludGVudCAi
>> "!B64TMP!" echo d2hhdCB0byByYW5rIGZvciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBbLS1t
>> "!B64TMP!" echo b2RlIHNpbWlsYXJ8Y2l0ZXJzfHJlZmVyZW5jZXNdIFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlm
>> "!B64TMP!" echo IHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3Ig
>> "!B64TMP!" echo dGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0
>> "!B64TMP!" echo cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQg
>> "!B64TMP!" echo cmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsg
>> "!B64TMP!" echo dHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29m
>> "!B64TMP!" echo Zi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3Qg
>> "!B64TMP!" echo cnVuIHRoZSBzY3JpcHQuCgpPbmUgdG8gdGVuIHNlZWQgcGFwZXIgSURzIChwb3NpdGlvbmFsKTsg
>> "!B64TMP!" echo dGhlIGZpcnN0IGlzIHRoZSBwcmltYXJ5IHNlZWQsIHRoZQpyZXN0IGFyZSBhbmNob3JzLiBgLS1p
>> "!B64TMP!" echo bnRlbnRgIChyZXF1aXJlZCkgaXMgYSBzaG9ydCBuYXR1cmFsLWxhbmd1YWdlCmRlc2NyaXB0aW9u
>> "!B64TMP!" echo IHRoYXQgcmFua3MgdGhlIGNhbmRpZGF0ZXMuIGAtLW1vZGVgIGRlZmF1bHRzIHRvIGBzaW1pbGFy
>> "!B64TMP!" echo YAooY28tY2l0YXRpb24gLyBiaWJsaW9ncmFwaGljIGNvdXBsaW5nKTsgYGNpdGVyc2AgcmV0dXJu
>> "!B64TMP!" echo cyBwYXBlcnMgY2l0aW5nIGEKc2VlZCwgYHJlZmVyZW5jZXNgIHBhcGVycyBjaXRlZCBieSBhIHNl
>> "!B64TMP!" echo ZWQuCgpQcmludHMgdGhlIHJhbmtlZCBjYW5kaWRhdGVzIGxpa2Ugd2ViX3Jlc2VhcmNoX3NlYXJj
>> "!B64TMP!" echo aC5weSwgdGhlbgpgKHBvb2xTaXplPU4pYCBhbmQgYW55IGBub3RlOmAgZnJvbSB0aGUgQVBJLiBg
>> "!B64TMP!" echo LS1qc29uYCBwcmludHMgdGhlIHJhdyBBUEkKcmVzcG9uc2UgaW5zdGVhZC4KCk5PVEU6IHJlc2Vh
>> "!B64TMP!" echo cmNoIHRvb2xzIG5lZWQgYSBGaXJlY3Jhd2wgYWNjb3VudCB3aXRoIHJlc2VhcmNoIHBlcm1pc3Np
>> "!B64TMP!" echo b25zCihzZXQgRklSRUNSQVdMX0FQSV9LRVksIGFuZCBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczov
>> "!B64TMP!" echo L2FwaS5maXJlY3Jhd2wuZGV2IGZvcgp0aGUgY2xvdWQgQVBJKTsgdGhlIHNlbGYtaG9zdGVkIHN0
>> "!B64TMP!" echo YWNrIG1heSBub3QgZXhwb3NlIHRoZW0uCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0
>> "!B64TMP!" echo IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgo
>> "!B64TMP!" echo X19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNy
>> "!B64TMP!" echo YXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCmltcG9ydCB3ZWJfcmVzZWFyY2hfc2VhcmNoICAj
>> "!B64TMP!" echo IHNpYmxpbmc6IHNoYXJlZCBwYXBlciBmb3JtYXR0ZXJzCgpFTkRQT0lOVCA9IGZjLnVybCgiL3Yx
>> "!B64TMP!" echo L3Jlc2VhcmNoL3JlbGF0ZWQiKQoKTU9ERVMgPSAoInNpbWlsYXIiLCAiY2l0ZXJzIiwgInJlZmVy
>> "!B64TMP!" echo ZW5jZXMiKQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAg
>> "!B64TMP!" echo c2VlZHMsIGludGVudCwgbW9kZSwgYXNfanNvbiA9IFtdLCBOb25lLCBOb25lLCBGYWxzZQogICAg
>> "!B64TMP!" echo aSA9IDAKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAg
>> "!B64TMP!" echo ICBpZiBhID09ICItLWludGVudCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBp
>> "!B64TMP!" echo ICs9IDEKICAgICAgICAgICAgaW50ZW50ID0gYXJnc1tpXQogICAgICAgIGVsaWYgYSA9PSAiLS1t
>> "!B64TMP!" echo b2RlIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAg
>> "!B64TMP!" echo ICBtb2RlID0gYXJnc1tpXQogICAgICAgICAgICBpZiBtb2RlIG5vdCBpbiBNT0RFUzoKICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgIHByaW50KGYiaW52YWxpZCAtLW1vZGU6IHttb2RlfSAob25lIG9mIHsnLCAnLmpv
>> "!B64TMP!" echo aW4oTU9ERVMpfSkiLAogICAgICAgICAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tanNvbiI6CiAgICAgICAg
>> "!B64TMP!" echo ICAgIGFzX2pzb24gPSBUcnVlCiAgICAgICAgZWxpZiBhLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAg
>> "!B64TMP!" echo ICAgICAgIHByaW50KGYidW5rbm93biBvcHRpb246IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
>> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbHNlOgogICAgICAgICAgICBzZWVkcy5hcHBlbmQo
>> "!B64TMP!" echo YSkKICAgICAgICBpICs9IDEKCiAgICBpZiBub3Qgc2VlZHMgb3Igbm90IGludGVudDoKICAgICAg
>> "!B64TMP!" echo ICBwcmludCgndXNhZ2U6IHdlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IDxzZWVkSWQ+IFtzZWVkSWQg
>> "!B64TMP!" echo Li4uXSAnCiAgICAgICAgICAgICAgJy0taW50ZW50ICJ3aGF0IHRvIHJhbmsgZm9yIiAnCiAgICAg
>> "!B64TMP!" echo ICAgICAgICAgJ1stLW1vZGUgc2ltaWxhcnxjaXRlcnN8cmVmZXJlbmNlc10gWy0tanNvbl0nLCBm
>> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKICAgIGlmIG5vdCAxIDw9IGxlbihzZWVk
>> "!B64TMP!" echo cykgPD0gMTA6CiAgICAgICAgcHJpbnQoInByb3ZpZGUgb25lIHRvIHRlbiBzZWVkIHBhcGVyIElE
>> "!B64TMP!" echo cyAoZmlyc3QgaXMgdGhlIHByaW1hcnkgc2VlZCkiLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0
>> "!B64TMP!" echo ZGVycikKICAgICAgICByZXR1cm4gMgoKICAgIGJvZHkgPSB7InNlZWRfaWRzIjogc2VlZHMsICJp
>> "!B64TMP!" echo bnRlbnQiOiBpbnRlbnR9CiAgICBpZiBtb2RlOgogICAgICAgIGJvZHlbIm1vZGUiXSA9IG1vZGUK
>> "!B64TMP!" echo CiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNhbGwoIi92MS9yZXNlYXJjaC9yZWxhdGVkIiwg
>> "!B64TMP!" echo bWV0aG9kPSJQT1NUIiwgYm9keT1ib2R5KQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAg
>> "!B64TMP!" echo ICAgICBwcmludChmIlJFU0VBUkNIIFJFTEFURUQgRkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRl
>> "!B64TMP!" echo cnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lz
>> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQo
>> "!B64TMP!" echo anNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAoKICAgIHBheWxvYWQgPSBkYXRhLmdl
>> "!B64TMP!" echo dCgiZGF0YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRh
>> "!B64TMP!" echo CiAgICBwcmludCh3ZWJfcmVzZWFyY2hfc2VhcmNoLmZtdF9oaXRzKAogICAgICAgIHdlYl9yZXNl
>> "!B64TMP!" echo YXJjaF9zZWFyY2guZXh0cmFjdF9yZXN1bHRzKGRhdGEpKSkKICAgIHBvb2xfc2l6ZSA9IHBheWxv
>> "!B64TMP!" echo YWQuZ2V0KCJwb29sU2l6ZSIpIG9yIDAKICAgIHByaW50KGYiKHBvb2xTaXplPXtwb29sX3NpemV9
>> "!B64TMP!" echo KSIpCiAgICBub3RlID0gcGF5bG9hZC5nZXQoIm5vdGUiKQogICAgaWYgbm90ZToKICAgICAgICBw
>> "!B64TMP!" echo cmludChmIm5vdGU6IHtub3RlfSIpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21h
>> "!B64TMP!" echo aW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_research_related.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_research_read.py ---
set "B64TMP=%TEMP%\LSR350004451.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZWFkIGluLWJvZHkgcGFzc2FnZXMgZnJvbSBvbmUg
>> "!B64TMP!" echo cmVzZWFyY2ggcGFwZXIgdGhhdCBhcmUgcmVsZXZhbnQgdG8gYQpzcGVjaWZpYyBxdWVzdGlvbiAo
>> "!B64TMP!" echo dGhlIGZpcmVjcmF3bF9yZXNlYXJjaF9yZWFkX3BhcGVyIE1DUCB0b29sKS4gRnVsbCB0ZXh0IGlz
>> "!B64TMP!" echo CmF2YWlsYWJsZSBvbmx5IGZvciBpbmRleGVkIHBhcGVycy4KClVzYWdlOgogICAgcHl0aG9uIHdl
>> "!B64TMP!" echo Yl9yZXNlYXJjaF9yZWFkLnB5IDxwYXBlcklkPiAiPHF1ZXN0aW9uPiIgWy0tanNvbl0KCkV4YW1w
>> "!B64TMP!" echo bGU6CiAgICBweXRob24gd2ViX3Jlc2VhcmNoX3JlYWQucHkgYXJ4aXY6MTcwNi4wMzc2MiAiaG93
>> "!B64TMP!" echo IGlzIGF0dGVudGlvbiBjb21wdXRlZD8iCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFy
>> "!B64TMP!" echo Y2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMg
>> "!B64TMP!" echo YXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2Ft
>> "!B64TMP!" echo ZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVx
>> "!B64TMP!" echo dWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81
>> "!B64TMP!" echo eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBu
>> "!B64TMP!" echo ZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQu
>> "!B64TMP!" echo CgpQcmludHMgdGhlIG1hdGNoaW5nIHBhc3NhZ2VzIHNlcGFyYXRlZCBieSBgLS0tYCBsaW5lcyAo
>> "!B64TMP!" echo bGlrZSB0aGUgTUNQIHRvb2wpLCBvcgphIG5vdGljZSB3aGVuIG5vIGZ1bGwgdGV4dCBpcyBhdmFp
>> "!B64TMP!" echo bGFibGUuIGAtLWpzb25gIHByaW50cyB0aGUgcmF3IEFQSQpyZXNwb25zZSBpbnN0ZWFkLgoKTk9U
>> "!B64TMP!" echo RTogcmVzZWFyY2ggdG9vbHMgbmVlZCBhIEZpcmVjcmF3bCBhY2NvdW50IHdpdGggcmVzZWFyY2gg
>> "!B64TMP!" echo cGVybWlzc2lvbnMKKHNldCBGSVJFQ1JBV0xfQVBJX0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJM
>> "!B64TMP!" echo PWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yCnRoZSBjbG91ZCBBUEkpOyB0aGUgc2VsZi1o
>> "!B64TMP!" echo b3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBv
>> "!B64TMP!" echo cwppbXBvcnQgc3lzCmltcG9ydCB1cmxsaWIucGFyc2UKCnN5cy5wYXRoLmluc2VydCgwLCBvcy5w
>> "!B64TMP!" echo YXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmlsZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xf
>> "!B64TMP!" echo YXBpIGFzIGZjICAjIHNpYmxpbmc6IEZpcmVjcmF3bCBIVFRQIGNsaWVudCArIHNlbGYtaGVhbAoK
>> "!B64TMP!" echo RU5EUE9JTlQgPSBmYy51cmwoIi92MS9yZXNlYXJjaC9wYXBlcnMiKQoKCmRlZiBtYWluKCkgLT4g
>> "!B64TMP!" echo aW50OgogICAgYXJncyA9IFthIGZvciBhIGluIHN5cy5hcmd2WzE6XSBpZiBhICE9ICItLWpzb24i
>> "!B64TMP!" echo XQogICAgYXNfanNvbiA9ICItLWpzb24iIGluIHN5cy5hcmd2WzE6XQogICAgaWYgbGVuKGFyZ3Mp
>> "!B64TMP!" echo ICE9IDIgb3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpIG9yIGFyZ3NbMV0uc3RhcnRzd2l0aCgi
>> "!B64TMP!" echo LS0iKToKICAgICAgICBwcmludCgndXNhZ2U6IHdlYl9yZXNlYXJjaF9yZWFkLnB5IDxwYXBlcklk
>> "!B64TMP!" echo PiAiPHF1ZXN0aW9uPiIgWy0tanNvbl0nLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikK
>> "!B64TMP!" echo ICAgICAgICByZXR1cm4gMgogICAgcGFwZXJfaWQsIHF1ZXN0aW9uID0gYXJncwoKICAgIHBhdGgg
>> "!B64TMP!" echo PSAoIi92MS9yZXNlYXJjaC9wYXBlcnMvIiArIHVybGxpYi5wYXJzZS5xdW90ZShwYXBlcl9pZCwg
>> "!B64TMP!" echo c2FmZT0iIikKICAgICAgICAgICAgKyAiL3JlYWQiKQogICAgdHJ5OgogICAgICAgIGRhdGEgPSBm
>> "!B64TMP!" echo Yy5jYWxsKHBhdGgsIG1ldGhvZD0iUE9TVCIsIGJvZHk9eyJxdWVzdGlvbiI6IHF1ZXN0aW9ufSkK
>> "!B64TMP!" echo ICAgIGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJSRVNFQVJDSCBSRUFE
>> "!B64TMP!" echo IEZBSUxFRCBmb3Ige3BhcGVyX2lkfToge2V9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIGlm
>> "!B64TMP!" echo IGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAg
>> "!B64TMP!" echo ICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAgICAgIHByaW50KGpzb24uZHVtcHMoZGF0
>> "!B64TMP!" echo YSkpCiAgICAgICAgcmV0dXJuIDAKCiAgICBwYXNzYWdlcyA9IGRhdGEuZ2V0KCJwYXNzYWdlcyIp
>> "!B64TMP!" echo CiAgICBpZiBwYXNzYWdlcyBpcyBOb25lOgogICAgICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0
>> "!B64TMP!" echo YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgXAogICAgICAgICAgICBl
>> "!B64TMP!" echo bHNlIGRhdGEKICAgICAgICBwYXNzYWdlcyA9IHBheWxvYWQuZ2V0KCJwYXNzYWdlcyIpCiAgICBp
>> "!B64TMP!" echo ZiBub3QgaXNpbnN0YW5jZShwYXNzYWdlcywgbGlzdCkgb3Igbm90IHBhc3NhZ2VzOgogICAgICAg
>> "!B64TMP!" echo IHByaW50KCIobm8gZnVsbC10ZXh0IHBhc3NhZ2VzIGF2YWlsYWJsZSBmb3IgdGhpcyBwYXBlciki
>> "!B64TMP!" echo KQogICAgICAgIHJldHVybiAwCiAgICB0ZXh0cyA9IFtwLmdldCgidGV4dCIpIGlmIGlzaW5zdGFu
>> "!B64TMP!" echo Y2UocCwgZGljdCkgZWxzZSBzdHIocCkKICAgICAgICAgICAgIGZvciBwIGluIHBhc3NhZ2VzXQog
>> "!B64TMP!" echo ICAgcHJpbnQoIlxuLS0tXG4iLmpvaW4odCBmb3IgdCBpbiB0ZXh0cyBpZiB0KSkKICAgIHJldHVy
>> "!B64TMP!" echo biAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_research_read.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_github_search.py ---
set "B64TMP=%TEMP%\LSR2130354046.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggaW5kZXhlZCBwdWJsaWMgR2l0SHViIGlz
>> "!B64TMP!" echo c3VlLCBwdWxsLXJlcXVlc3QsIGFuZCBSRUFETUUgY29udGVudCB2aWEKdGhlIEZpcmVjcmF3bCBy
>> "!B64TMP!" echo ZXNlYXJjaCBpbmRleCAodGhlIGZpcmVjcmF3bF9yZXNlYXJjaF9zZWFyY2hfZ2l0aHViIE1DUAp0
>> "!B64TMP!" echo b29sKS4KClVzYWdlOgogICAgcHl0aG9uIHdlYl9naXRodWJfc2VhcmNoLnB5ICI8cXVlcnk+IiBb
>> "!B64TMP!" echo LS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVh
>> "!B64TMP!" echo Y2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBz
>> "!B64TMP!" echo Y3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJl
>> "!B64TMP!" echo X3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24g
>> "!B64TMP!" echo ZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJl
>> "!B64TMP!" echo dHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJl
>> "!B64TMP!" echo X3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIHRoZSByYW5r
>> "!B64TMP!" echo ZWQgbWF0Y2hlcyBleGFjdGx5IGxpa2UgdGhlIE1DUCB0b29sIGRvZXMg4oCUIGZvciBlYWNoIGhp
>> "!B64TMP!" echo dDoKCiAgICBbcmVwbyMxMjNdIChwdWxsX3JlcXVlc3QsIDUgc2VnbWVudHMpCiAgICBodHRwczov
>> "!B64TMP!" echo L2dpdGh1Yi5jb20vLi4uCiAgICBtYXRjaGVkIGNvbnRlbnQgKHVwIHRvIDEyMDAgY2hhcnMpCgpg
>> "!B64TMP!" echo LS1qc29uYCBwcmludHMgdGhlIHJhdyBBUEkgcmVzcG9uc2UgaW5zdGVhZC4KCk5PVEU6IHJlc2Vh
>> "!B64TMP!" echo cmNoIHRvb2xzIG5lZWQgYSBGaXJlY3Jhd2wgYWNjb3VudCB3aXRoIHJlc2VhcmNoIHBlcm1pc3Np
>> "!B64TMP!" echo b25zCihzZXQgRklSRUNSQVdMX0FQSV9LRVksIGFuZCBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczov
>> "!B64TMP!" echo L2FwaS5maXJlY3Jhd2wuZGV2IGZvcgp0aGUgY2xvdWQgQVBJKTsgdGhlIHNlbGYtaG9zdGVkIHN0
>> "!B64TMP!" echo YWNrIG1heSBub3QgZXhwb3NlIHRoZW0uCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0
>> "!B64TMP!" echo IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgo
>> "!B64TMP!" echo X19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNy
>> "!B64TMP!" echo YXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL3Jlc2Vh
>> "!B64TMP!" echo cmNoL3NlYXJjaC9naXRodWIiKQoKTUFYX0NPTlRFTlRfQ0hBUlMgPSAxMjAwCgoKZGVmIGZtdF9n
>> "!B64TMP!" echo aXRodWIocmVzdWx0cyk6CiAgICAiIiJGb3JtYXQgcmFua2VkIEdpdEh1YiBtYXRjaGVzIChtaXJy
>> "!B64TMP!" echo b3JzIHRoZSBNQ1AgdG9vbCdzIGZvcm1hdHRlcikuIiIiCiAgICBpZiBub3QgcmVzdWx0czoKICAg
>> "!B64TMP!" echo ICAgICByZXR1cm4gIihubyByZXN1bHRzKSIKICAgIGJsb2NrcyA9IFtdCiAgICBmb3IgciBpbiBy
>> "!B64TMP!" echo ZXN1bHRzOgogICAgICAgIGlmIG5vdCBpc2luc3RhbmNlKHIsIGRpY3QpOgogICAgICAgICAgICBi
>> "!B64TMP!" echo bG9ja3MuYXBwZW5kKHN0cihyKSkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBsaW5lcyA9
>> "!B64TMP!" echo IFtdCiAgICAgICAgcmVwbyA9IHIuZ2V0KCJyZXBvIikgb3IgIj8iCiAgICAgICAgbnVtYmVyID0g
>> "!B64TMP!" echo ci5nZXQoIm51bWJlciIpCiAgICAgICAgaWYgbnVtYmVyIGlzIE5vbmUgYW5kIHIuZ2V0KCJwYWdl
>> "!B64TMP!" echo VHlwZSIpIGlzIE5vbmU6CiAgICAgICAgICAgIGxpbmVzLmFwcGVuZChmIlt7cmVwb31dIFJFQURN
>> "!B64TMP!" echo RSIpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcmVmID0gZiIje251bWJlcn0iIGlmIG51bWJl
>> "!B64TMP!" echo ciBpcyBub3QgTm9uZSBlbHNlICIiCiAgICAgICAgICAgIG1ldGFfcGFydHMgPSBbc3RyKHIuZ2V0
>> "!B64TMP!" echo KCJwYWdlVHlwZSIpIG9yICIiKV0KICAgICAgICAgICAgaWYgci5nZXQoInNlZ21lbnRDb3VudCIp
>> "!B64TMP!" echo OgogICAgICAgICAgICAgICAgbWV0YV9wYXJ0cy5hcHBlbmQoZiJ7clsnc2VnbWVudENvdW50J119
>> "!B64TMP!" echo IHNlZ21lbnRzIikKICAgICAgICAgICAgbWV0YSA9ICIsICIuam9pbihwIGZvciBwIGluIG1ldGFf
>> "!B64TMP!" echo cGFydHMgaWYgcCkKICAgICAgICAgICAgbGluZXMuYXBwZW5kKGYiW3tyZXBvfXtyZWZ9XSIgKyAo
>> "!B64TMP!" echo ZiIgKHttZXRhfSkiIGlmIG1ldGEgZWxzZSAiIikpCiAgICAgICAgdXJsID0gci5nZXQoInJlYWRt
>> "!B64TMP!" echo ZVVybCIpIG9yIHIuZ2V0KCJ1cmwiKQogICAgICAgIGlmIHVybDoKICAgICAgICAgICAgbGluZXMu
>> "!B64TMP!" echo YXBwZW5kKHVybCkKICAgICAgICBib2R5ID0gKHIuZ2V0KCJjb250ZW50TWQiKSBvciByLmdldCgi
>> "!B64TMP!" echo c25pcHBldCIpIG9yICIiKS5zdHJpcCgpCiAgICAgICAgbGluZXMuYXBwZW5kKGJvZHlbOk1BWF9D
>> "!B64TMP!" echo T05URU5UX0NIQVJTXSBpZiBib2R5IGVsc2UgIihubyBjb250ZW50KSIpCiAgICAgICAgYmxvY2tz
>> "!B64TMP!" echo LmFwcGVuZCgiXG4iLmpvaW4obGluZXMpKQogICAgcmV0dXJuICJcblxuIi5qb2luKGJsb2NrcykK
>> "!B64TMP!" echo CgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBbYSBmb3IgYSBpbiBzeXMuYXJndlsxOl0g
>> "!B64TMP!" echo aWYgYSAhPSAiLS1qc29uIl0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBzeXMuYXJndlsxOl0K
>> "!B64TMP!" echo ICAgIHF1ZXJ5ID0gIiAiLmpvaW4oYXJncykuc3RyaXAoKQogICAgaWYgbm90IHF1ZXJ5OgogICAg
>> "!B64TMP!" echo ICAgIHByaW50KCd1c2FnZTogd2ViX2dpdGh1Yl9zZWFyY2gucHkgIjxxdWVyeT4iIFstLWpzb25d
>> "!B64TMP!" echo JywgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCgogICAgdHJ5OgogICAgICAgIGRh
>> "!B64TMP!" echo dGEgPSBmYy5jYWxsKCIvdjEvcmVzZWFyY2gvc2VhcmNoL2dpdGh1YiIsIG1ldGhvZD0iUE9TVCIs
>> "!B64TMP!" echo CiAgICAgICAgICAgICAgICAgICAgICAgYm9keT17InF1ZXJ5IjogcXVlcnl9KQogICAgZXhjZXB0
>> "!B64TMP!" echo IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIkdJVEhVQiBTRUFSQ0ggRkFJTEVEOiB7
>> "!B64TMP!" echo ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmlu
>> "!B64TMP!" echo dChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pz
>> "!B64TMP!" echo b246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAg
>> "!B64TMP!" echo cmVzdWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIikKICAgIGlmIHJlc3VsdHMgaXMgTm9uZToKICAg
>> "!B64TMP!" echo ICAgICBwYXlsb2FkID0gZGF0YS5nZXQoImRhdGEiKSBpZiBpc2luc3RhbmNlKGRhdGEuZ2V0KCJk
>> "!B64TMP!" echo YXRhIiksIGRpY3QpIFwKICAgICAgICAgICAgZWxzZSBkYXRhCiAgICAgICAgcmVzdWx0cyA9IHBh
>> "!B64TMP!" echo eWxvYWQuZ2V0KCJyZXN1bHRzIikKICAgIGlmIG5vdCBpc2luc3RhbmNlKHJlc3VsdHMsIGxpc3Qp
>> "!B64TMP!" echo OgogICAgICAgIHJlc3VsdHMgPSBbXQogICAgcHJpbnQoZm10X2dpdGh1YihyZXN1bHRzKSkKICAg
>> "!B64TMP!" echo IHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4o
>> "!B64TMP!" echo KSkK
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_github_search.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/scripts/web_developer_search.py ---
set "B64TMP=%TEMP%\LSR2942363407.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggdGhlIEZpcmVjcmF3bCBkZXZlbG9wZXIg
>> "!B64TMP!" echo aW5kZXgg4oCUIGJ1aWx0IGZvciBjb2RpbmcgYWdlbnRzLCBjb3ZlcmluZwpHaXRIdWIgaXNzdWVz
>> "!B64TMP!" echo LCBtZXJnZWQgcHVsbCByZXF1ZXN0cywgcmVwb3NpdG9yeSBSRUFETUVzLCBhbmQgY3VyYXRlZApk
>> "!B64TMP!" echo b2N1bWVudGF0aW9uIHNpdGVzICh0aGUgZmlyZWNyYXdsX2RldmVsb3Blcl9zZWFyY2ggTUNQIHRv
>> "!B64TMP!" echo b2wpLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2RldmVsb3Blcl9zZWFyY2gucHkgIjxxdWVyeT4i
>> "!B64TMP!" echo IFstLXNraWxscy1vbmx5XSBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJz
>> "!B64TMP!" echo IGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNh
>> "!B64TMP!" echo bWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJl
>> "!B64TMP!" echo cXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0Mjkv
>> "!B64TMP!" echo NXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1Qg
>> "!B64TMP!" echo bmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0
>> "!B64TMP!" echo LgoKVXNlIGl0IGZvciBkZXZlbG9wZXIgcXVlc3Rpb25zIOKAlCBjb2RlIGJlaGF2aW91ciwgYSBs
>> "!B64TMP!" echo aWJyYXJ5IG9yIGZyYW1ld29yaywgYW4KQVBJIGNvbnRyYWN0LCBhbiBlcnJvciBtZXNzYWdlLCBv
>> "!B64TMP!" echo ciBhIGtub3duIGJ1Zy4gYC0tc2tpbGxzLW9ubHlgIGxpbWl0cyB0aGUKc2VhcmNoIHRvIGFnZW50
>> "!B64TMP!" echo LXNraWxsIGZpbGVzLiBQcmludHMgdGhlIHJhbmtlZCByZXN1bHRzIGV4YWN0bHkgbGlrZSB0aGUg
>> "!B64TMP!" echo TUNQCnRvb2wgZG9lcyDigJQgZm9yIGVhY2ggaGl0OgoKICAgICMjIFtpZF0gKGtpbmQpIHRpdGxl
>> "!B64TMP!" echo CiAgICBodHRwczovLy4uLgogICAgbWF0Y2hlZCBwYXNzYWdlcyAodXAgdG8gMTIwMCBjaGFycywg
>> "!B64TMP!" echo c2VwYXJhdGVkIGJ5IC0tLSkKCmAtLWpzb25gIHByaW50cyB0aGUgcmF3IEFQSSByZXNwb25zZSBp
>> "!B64TMP!" echo bnN0ZWFkLgoKTk9URTogZGV2ZWxvcGVyIHNlYXJjaCBuZWVkcyBhIEZpcmVjcmF3bCBhY2NvdW50
>> "!B64TMP!" echo IHdpdGggZGV2ZWxvcGVyLXNlYXJjaApwZXJtaXNzaW9ucyAoc2V0IEZJUkVDUkFXTF9BUElfS0VZ
>> "!B64TMP!" echo LCBhbmQKRklSRUNSQVdMX0FQSV9VUkw9aHR0cHM6Ly9hcGkuZmlyZWNyYXdsLmRldiBmb3IgdGhl
>> "!B64TMP!" echo IGNsb3VkIEFQSSk7IHRoZQpzZWxmLWhvc3RlZCBzdGFjayBtYXkgbm90IGV4cG9zZSBpdC4KIiIi
>> "!B64TMP!" echo CmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3Mu
>> "!B64TMP!" echo cGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXds
>> "!B64TMP!" echo X2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwK
>> "!B64TMP!" echo CkVORFBPSU5UID0gZmMudXJsKCIvdjEvZGV2ZWxvcGVyL3NlYXJjaCIpCgpNQVhfUEFTU0FHRV9D
>> "!B64TMP!" echo SEFSUyA9IDEyMDAKCgpkZWYgZm10X2RldmVsb3BlcihyZXN1bHRzKToKICAgICIiIkZvcm1hdCBy
>> "!B64TMP!" echo YW5rZWQgZGV2ZWxvcGVyLWluZGV4IHJlc3VsdHMgKG1pcnJvcnMgdGhlIE1DUCBmb3JtYXR0ZXIp
>> "!B64TMP!" echo LiIiIgogICAgaWYgbm90IHJlc3VsdHM6CiAgICAgICAgcmV0dXJuICIobm8gcmVzdWx0cykiCiAg
>> "!B64TMP!" echo ICBibG9ja3MgPSBbXQogICAgZm9yIHIgaW4gcmVzdWx0czoKICAgICAgICBpZiBub3QgaXNpbnN0
>> "!B64TMP!" echo YW5jZShyLCBkaWN0KToKICAgICAgICAgICAgYmxvY2tzLmFwcGVuZChzdHIocikpCiAgICAgICAg
>> "!B64TMP!" echo ICAgIGNvbnRpbnVlCiAgICAgICAgcmlkID0gci5nZXQoImlkIikgb3IgIj8iCiAgICAgICAga2lu
>> "!B64TMP!" echo ZCA9IHN0cihyaWQpLnNwbGl0KCI6IiwgMSlbMF0KICAgICAgICBsaW5lcyA9IFsiIyMgW3t9XXt9
>> "!B64TMP!" echo IHt9Ii5mb3JtYXQocmlkLCBmIiAoe2tpbmR9KSIgaWYga2luZCBlbHNlICIiLAogICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICByLmdldCgidGl0bGUiKSBvciAiKHVudGl0bGVk
>> "!B64TMP!" echo KSIpXQogICAgICAgIGlmIHIuZ2V0KCJ1cmwiKToKICAgICAgICAgICAgbGluZXMuYXBwZW5kKHJb
>> "!B64TMP!" echo InVybCJdKQogICAgICAgIHBhc3NhZ2VzID0gci5nZXQoInBhc3NhZ2VzIikKICAgICAgICBib2R5
>> "!B64TMP!" echo ID0gIiIKICAgICAgICBpZiBpc2luc3RhbmNlKHBhc3NhZ2VzLCBsaXN0KToKICAgICAgICAgICAg
>> "!B64TMP!" echo Ym9keSA9ICJcbi0tLVxuIi5qb2luKChwLmdldCgidGV4dCIpIG9yICIiKQogICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgaWYgaXNpbnN0YW5jZShwLCBkaWN0KSBlbHNlIHN0cihwKQog
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZm9yIHAgaW4gcGFzc2FnZXMpLnN0cmlw
>> "!B64TMP!" echo KCkKICAgICAgICBsaW5lcy5hcHBlbmQoYm9keVs6TUFYX1BBU1NBR0VfQ0hBUlNdIGlmIGJvZHkg
>> "!B64TMP!" echo ZWxzZSAiKG5vIGNvbnRlbnQpIikKICAgICAgICBibG9ja3MuYXBwZW5kKCJcbiIuam9pbihsaW5l
>> "!B64TMP!" echo cykpCiAgICByZXR1cm4gIlxuXG4iLmpvaW4oYmxvY2tzKQoKCmRlZiBtYWluKCkgLT4gaW50Ogog
>> "!B64TMP!" echo ICAgYXJncyA9IFthIGZvciBhIGluIHN5cy5hcmd2WzE6XSBpZiBhICE9ICItLWpzb24iIGFuZCBh
>> "!B64TMP!" echo ICE9ICItLXNraWxscy1vbmx5Il0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBzeXMuYXJndlsx
>> "!B64TMP!" echo Ol0KICAgIHNraWxsc19vbmx5ID0gIi0tc2tpbGxzLW9ubHkiIGluIHN5cy5hcmd2WzE6XQogICAg
>> "!B64TMP!" echo cXVlcnkgPSAiICIuam9pbihhcmdzKS5zdHJpcCgpCiAgICBpZiBub3QgcXVlcnk6CiAgICAgICAg
>> "!B64TMP!" echo cHJpbnQoJ3VzYWdlOiB3ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSAiPHF1ZXJ5PiIgWy0tc2tpbGxz
>> "!B64TMP!" echo LW9ubHldIFstLWpzb25dJywKICAgICAgICAgICAgICBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
>> "!B64TMP!" echo cmV0dXJuIDIKCiAgICBib2R5ID0geyJxdWVyeSI6IHF1ZXJ5fQogICAgaWYgc2tpbGxzX29ubHk6
>> "!B64TMP!" echo CiAgICAgICAgYm9keVsic2tpbGxzIl0gPSAib25seSIKCiAgICB0cnk6CiAgICAgICAgZGF0YSA9
>> "!B64TMP!" echo IGZjLmNhbGwoIi92MS9kZXZlbG9wZXIvc2VhcmNoIiwgbWV0aG9kPSJQT1NUIiwgYm9keT1ib2R5
>> "!B64TMP!" echo KQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIkRFVkVMT1BFUiBT
>> "!B64TMP!" echo RUFSQ0ggRkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50Ogog
>> "!B64TMP!" echo ICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4g
>> "!B64TMP!" echo MQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAg
>> "!B64TMP!" echo ICByZXR1cm4gMAogICAgcmVzdWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIikKICAgIGlmIHJlc3Vs
>> "!B64TMP!" echo dHMgaXMgTm9uZToKICAgICAgICBwYXlsb2FkID0gZGF0YS5nZXQoImRhdGEiKSBpZiBpc2luc3Rh
>> "!B64TMP!" echo bmNlKGRhdGEuZ2V0KCJkYXRhIiksIGRpY3QpIFwKICAgICAgICAgICAgZWxzZSBkYXRhCiAgICAg
>> "!B64TMP!" echo ICAgcmVzdWx0cyA9IHBheWxvYWQuZ2V0KCJyZXN1bHRzIikgb3IgcGF5bG9hZC5nZXQoImRldmVs
>> "!B64TMP!" echo b3BlciIpCiAgICBpZiBub3QgaXNpbnN0YW5jZShyZXN1bHRzLCBsaXN0KToKICAgICAgICByZXN1
>> "!B64TMP!" echo bHRzID0gW10KICAgIHByaW50KGZtdF9kZXZlbG9wZXIocmVzdWx0cykpCiAgICByZXR1cm4gMAoK
>> "!B64TMP!" echo CmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_developer_search.py"
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
>> "!B64TMP!" echo IGJ1bmRsZWQgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCBza2lsbCAobGljZW5zZWQgYnkgdGhlIHRv
>> "!B64TMP!" echo cC1sZXZlbCBMSUNFTlNFKSAtLS0tCiAgICAoImxvY2FsLXdlYi1zZWFyY2gvU0tJTEwubWQiLCAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAibG9jYWwtd2ViLXNlYXJjaC9TS0lMTC5tZCIpLAogICAgIyBjb3Jl
>> "!B64TMP!" echo LW9ubHkgU0tJTEwubWQgdmFyaWFudDogbWF0ZXJpYWxpc2VkIGxpa2UgYW55IG90aGVyIGZpbGUs
>> "!B64TMP!" echo IHRoZW4gZWl0aGVyCiAgICAjIHN3YXBwZWQgaW4gb3ZlciBTS0lMTC5tZCAobm8gRmlyZWNyYXds
>> "!B64TMP!" echo IGFjY291bnQpIG9yIGRlbGV0ZWQgKGFjY291bnQgbW9kZSkKICAgICMgYnkgdGhlIHRyaW0gc3Rl
>> "!B64TMP!" echo cCB0aGUgZ2VuZXJhdG9ycyBlbWl0IG5lYXIgdGhlIHNraWxsIGluc3RhbGxhdGlvbi4KICAgICgi
>> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9TS0lMTC1jb3JlLm1kIiwgICAgICAgICAgICAgICJsb2NhbC13ZWIt
>> "!B64TMP!" echo c2VhcmNoL1NLSUxMLWNvcmUubWQiKSwKICAgICgibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL2Nv
>> "!B64TMP!" echo bmZpZy5weSIsICAgICAgICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvY29uZmlnLnB5Iiks
>> "!B64TMP!" echo CiAgICAoImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkiLCAgICAibG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaC9zY3JpcHRzL2Vuc3VyZV9zdGFjay5weSIpLAogICAgKCJsb2NhbC13ZWIt
>> "!B64TMP!" echo c2VhcmNoL3NjcmlwdHMvZmlyZWNyYXdsX2FwaS5weSIsICAgImxvY2FsLXdlYi1zZWFyY2gvc2Ny
>> "!B64TMP!" echo aXB0cy9maXJlY3Jhd2xfYXBpLnB5IiksCiAgICAoImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfc2VhcmNoLnB5IiwgICAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9zZWFyY2gu
>> "!B64TMP!" echo cHkiKSwKICAgICgibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9zY3JhcGUucHkiLCAgICAg
>> "!B64TMP!" echo ICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3NjcmFwZS5weSIpLAogICAgIyAtLS0tIHRo
>> "!B64TMP!" echo ZSAyNCBGaXJlY3Jhd2wgTUNQLWVxdWl2YWxlbnQgdG9vbHMgKHdlYl9zZWFyY2gvd2ViX3NjcmFw
>> "!B64TMP!" echo ZSBhYm92ZSArIHRoZXNlIDIyKSAtLS0tCiAgICAoImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfbWFwLnB5IiwgICAgICAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tYXAucHki
>> "!B64TMP!" echo KSwKICAgICgibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9jcmF3bC5weSIsICAgICAgICJs
>> "!B64TMP!" echo b2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2NyYXdsLnB5IiksCiAgICAoImxvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gvc2NyaXB0cy93ZWJfY3Jhd2xfc3RhdHVzLnB5IiwgImxvY2FsLXdlYi1zZWFyY2gvc2Ny
>> "!B64TMP!" echo aXB0cy93ZWJfY3Jhd2xfc3RhdHVzLnB5IiksCiAgICAoImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfYWdlbnQucHkiLCAgICAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9hZ2Vu
>> "!B64TMP!" echo dC5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2FnZW50X3N0YXR1cy5w
>> "!B64TMP!" echo eSIsICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2FnZW50X3N0YXR1cy5weSIpLAogICAg
>> "!B64TMP!" echo KCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2ludGVyYWN0LnB5IiwgICAgImxvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2gvc2NyaXB0cy93ZWJfaW50ZXJhY3QucHkiKSwKICAgICgibG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aC9zY3JpcHRzL3dlYl9pbnRlcmFjdF9zdG9wLnB5IiwgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfaW50ZXJhY3Rfc3RvcC5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMv
>> "!B64TMP!" echo d2ViX3BhcnNlLnB5IiwgICAgICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfcGFyc2Uu
>> "!B64TMP!" echo cHkiKSwKICAgICgibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9yX2NyZWF0ZS5w
>> "!B64TMP!" echo eSIsICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfY3JlYXRlLnB5IiksCiAg
>> "!B64TMP!" echo ICAoImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9saXN0LnB5IiwgICAibG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9yX2xpc3QucHkiKSwKICAgICgibG9jYWwt
>> "!B64TMP!" echo d2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9yX2dldC5weSIsICAgICJsb2NhbC13ZWItc2Vh
>> "!B64TMP!" echo cmNoL3NjcmlwdHMvd2ViX21vbml0b3JfZ2V0LnB5IiksCiAgICAoImxvY2FsLXdlYi1zZWFyY2gv
>> "!B64TMP!" echo c2NyaXB0cy93ZWJfbW9uaXRvcl91cGRhdGUucHkiLCAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9tb25pdG9yX3VwZGF0ZS5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMv
>> "!B64TMP!" echo d2ViX21vbml0b3JfZGVsZXRlLnB5IiwgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9u
>> "!B64TMP!" echo aXRvcl9kZWxldGUucHkiKSwKICAgICgibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25p
>> "!B64TMP!" echo dG9yX3J1bi5weSIsICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfcnVu
>> "!B64TMP!" echo LnB5IiksCiAgICAoImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9jaGVja3Mu
>> "!B64TMP!" echo cHkiLCAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9yX2NoZWNrcy5weSIpLAog
>> "!B64TMP!" echo ICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfY2hlY2sucHkiLCAgImxv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9jaGVjay5weSIpLAogICAgKCJsb2Nh
>> "!B64TMP!" echo bC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3Jlc2VhcmNoX3NlYXJjaC5weSIsICAgImxvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfc2VhcmNoLnB5IiksCiAgICAoImxvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSIsICAibG9jYWwtd2ViLXNl
>> "!B64TMP!" echo YXJjaC9zY3JpcHRzL3dlYl9yZXNlYXJjaF9pbnNwZWN0LnB5IiksCiAgICAoImxvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfcmVsYXRlZC5weSIsICAibG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aC9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IiksCiAgICAoImxvY2FsLXdlYi1zZWFy
>> "!B64TMP!" echo Y2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfcmVhZC5weSIsICAgICAibG9jYWwtd2ViLXNlYXJjaC9z
>> "!B64TMP!" echo Y3JpcHRzL3dlYl9yZXNlYXJjaF9yZWFkLnB5IiksCiAgICAoImxvY2FsLXdlYi1zZWFyY2gvc2Ny
>> "!B64TMP!" echo aXB0cy93ZWJfZ2l0aHViX3NlYXJjaC5weSIsICAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9naXRodWJfc2VhcmNoLnB5IiksCiAgICAoImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSIsICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9k
>> "!B64TMP!" echo ZXZlbG9wZXJfc2VhcmNoLnB5IiksCiAgICAoImluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCIsICAg
>> "!B64TMP!" echo ICAgICAgICAgICJpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQiKSwKXQoKCiMgVGhlIDE5IGFjY291
>> "!B64TMP!" echo bnQtZ2F0ZWQgdG9vbCBzY3JpcHRzOiB0aGV5IG9ubHkgd29yayBhZ2FpbnN0IGEgRmlyZWNyYXds
>> "!B64TMP!" echo CiMgYWNjb3VudCAodGhlIGNsb3VkIEFQSSksIHNvIHRoZSBpbnN0YWxsZXJzIGFzayBhIHkvTiAi
>> "!B64TMP!" echo QWRkIGEgRmlyZWNyYXdsCiMgYWNjb3VudD8iIHF1ZXN0aW9uIChkZWZhdWx0IE4pIGFuZCwgd2hl
>> "!B64TMP!" echo biBhbnN3ZXJlZCBOLCBkZWxldGUgdGhlc2Ugc2NyaXB0cwojIGZyb20gdGhlIGJ1bmRsZWQgc2tp
>> "!B64TMP!" echo bGwgYW5kIHN3YXAgaW4gdGhlIGNvcmUtb25seSBTS0lMTC5tZCAoU0tJTEwtY29yZS5tZCkuCkFD
>> "!B64TMP!" echo Q09VTlRfVE9PTFMgPSBbCiAgICAid2ViX2FnZW50LnB5IiwgIndlYl9hZ2VudF9zdGF0dXMucHki
>> "!B64TMP!" echo LAogICAgIndlYl9pbnRlcmFjdC5weSIsICJ3ZWJfaW50ZXJhY3Rfc3RvcC5weSIsCiAgICAid2Vi
>> "!B64TMP!" echo X3BhcnNlLnB5IiwKICAgICJ3ZWJfbW9uaXRvcl9jcmVhdGUucHkiLCAid2ViX21vbml0b3JfbGlz
>> "!B64TMP!" echo dC5weSIsICJ3ZWJfbW9uaXRvcl9nZXQucHkiLAogICAgIndlYl9tb25pdG9yX3VwZGF0ZS5weSIs
>> "!B64TMP!" echo ICJ3ZWJfbW9uaXRvcl9kZWxldGUucHkiLCAid2ViX21vbml0b3JfcnVuLnB5IiwKICAgICJ3ZWJf
>> "!B64TMP!" echo bW9uaXRvcl9jaGVja3MucHkiLCAid2ViX21vbml0b3JfY2hlY2sucHkiLAogICAgIndlYl9yZXNl
>> "!B64TMP!" echo YXJjaF9zZWFyY2gucHkiLCAid2ViX3Jlc2VhcmNoX2luc3BlY3QucHkiLAogICAgIndlYl9yZXNl
>> "!B64TMP!" echo YXJjaF9yZWxhdGVkLnB5IiwgIndlYl9yZXNlYXJjaF9yZWFkLnB5IiwKICAgICJ3ZWJfZ2l0aHVi
>> "!B64TMP!" echo X3NlYXJjaC5weSIsICJ3ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSIsCl0KCgpkZWYgcmVhZChyZWwp
>> "!B64TMP!" echo OgogICAgd2l0aCBvcGVuKG9zLnBhdGguam9pbihTUkMsIHJlbCksICJyYiIpIGFzIGY6CiAgICAg
>> "!B64TMP!" echo ICAgcmV0dXJuIGYucmVhZCgpCgoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQojICBXaW5kb3dzIGlu
>> "!B64TMP!" echo c3RhbGxlciAoLmJhdCkKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQoKZGVmIGI2NF9jaHVua2VkKGRh
>> "!B64TMP!" echo dGEsIHdpZHRoPTc2KToKICAgICIiIlJldHVybiBsaXN0IG9mIDw9d2lkdGgtY2hhciBiYXNlNjQg
>> "!B64TMP!" echo bGluZXMuIiIiCiAgICBzID0gYmFzZTY0LmI2NGVuY29kZShkYXRhKS5kZWNvZGUoImFzY2lpIikK
>> "!B64TMP!" echo ICAgIHJldHVybiBbc1tpOmkrd2lkdGhdIGZvciBpIGluIHJhbmdlKDAsIGxlbihzKSwgd2lkdGgp
>> "!B64TMP!" echo XQoKCmRlZiBnZW5fYmF0KCk6CiAgICBvdXQgPSBbXQogICAgYXAgPSBvdXQuYXBwZW5kCgogICAg
>> "!B64TMP!" echo YXAoJ0BlY2hvIG9mZicpCiAgICBhcCgnc2V0bG9jYWwgZW5hYmxlRGVsYXllZEV4cGFuc2lvbicp
>> "!B64TMP!" echo CiAgICBhcCgnY2hjcCA2NTAwMSA+bnVsJykKICAgIGFwKCd0aXRsZSBMb2NhbCBTZWFyY2ggLSBJ
>> "!B64TMP!" echo bnN0YWxsZXInKQogICAgYXAoJycpCiAgICBhcCgnUkVNID09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAg
>> "!B64TMP!" echo ICBhcCgnUkVNICBMb2NhbCBTZWFyY2ggSW5zdGFsbGVyICAoRmlyZWNyYXdsICsgU2VhclhORyAr
>> "!B64TMP!" echo IGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwpICAtICBXaW5kb3dzJykKICAgIGFwKCdSRU0gPT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09JykKICAgIGFwKCdSRU0gIFNlbGYtY29udGFpbmVkOiBldmVyeSBmaWxlIHRo
>> "!B64TMP!" echo ZSBpbnN0YWxsZXIgbmVlZHMgaXMgZW1iZWRkZWQgYmVsb3cgYXMnKQogICAgYXAoJ1JFTSAgYmFz
>> "!B64TMP!" echo ZTY0LiBJZiBhIHNvdXJjZSBmaWxlIGlzIG1pc3NpbmcgZnJvbSB0aGlzIHNjcmlwdFwncyBmb2xk
>> "!B64TMP!" echo ZXIgKGUuZy4geW91JykKICAgIGFwKCdSRU0gIG9ubHkgZG93bmxvYWRlZCB0aGlzIG9uZSAuYmF0
>> "!B64TMP!" echo KSwgdGhlIGVtYmVkZGVkIGNvcHkgaXMgdXNlZCBpbnN0ZWFkLicpCiAgICBhcCgnUkVNICBBZnRl
>> "!B64TMP!" echo ciBpbnN0YWxsaW5nIHRoZSBzdGFjayBpdCBhbHNvIGNvcGllcyB0aGUgYnVuZGxlZCBsb2NhbC13
>> "!B64TMP!" echo ZWItc2VhcmNoIGFnZW50JykKICAgIGFwKCdSRU0gIHNraWxsIGludG8gJVVTRVJQUk9GSUxFJVxc
>> "!B64TMP!" echo LmFnZW50c1xcc2tpbGxzXFxsb2NhbC13ZWItc2VhcmNoLicpCiAgICBhcCgnUkVNICBUaGUgaW5z
>> "!B64TMP!" echo dGFsbGVyIGFza3MgYSB5L04gIkFkZCBhIEZpcmVjcmF3bCBhY2NvdW50PyIgcXVlc3Rpb24gKGRl
>> "!B64TMP!" echo ZmF1bHQgTik6JykKICAgIGFwKCdSRU0gIHdpdGhvdXQgYW4gYWNjb3VudCBvbmx5IHRoZSBmcmVl
>> "!B64TMP!" echo IGxvY2FsIHNraWxsIHRvb2xzIGFyZSBpbnN0YWxsZWQgKHRoZScpCiAgICBhcCgnUkVNICAxOSBh
>> "!B64TMP!" echo Y2NvdW50LWdhdGVkIHNjcmlwdHMgYXJlIHNraXBwZWQgYW5kIGEgY29yZS1vbmx5IFNLSUxMLm1k
>> "!B64TMP!" echo IGlzIHVzZWQpOycpCiAgICBhcCgnUkVNICB3aXRoIG9uZSB0aGUgY3JlZGVudGlhbHMgYXJlIHdy
>> "!B64TMP!" echo aXR0ZW4gdG8gLmVudiBhbmQgYWxsIDI0IHRvb2xzIGluc3RhbGwuJykKICAgIGFwKCdSRU0gIElm
>> "!B64TMP!" echo IHRoZSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5uaW5nLCB0aGUgaW5zdGFsbGVyIGxhdW5jaGVz
>> "!B64TMP!" echo IERvY2tlcicpCiAgICBhcCgnUkVNICBEZXNrdG9wIGF1dG9tYXRpY2FsbHkgYW5kIHdhaXRzIGZv
>> "!B64TMP!" echo ciBpdCBiZWZvcmUgcHVsbGluZyBpbWFnZXMuJykKICAgIGFwKCdSRU0gPT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09JykKICAgIGFwKCcnKQogICAgYXAoJ2VjaG8gPT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCdlY2hvICAgTG9jYWwg
>> "!B64TMP!" echo U2VhcmNoIEluc3RhbGxlciAgKEZpcmVjcmF3bCArIFNlYXJYTkcgKyBsb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo KScpCiAgICBhcCgnZWNobyAgIEEgbG9jYWwgd2ViLWJyb3dzaW5nIHN5c3RlbSBmb3IgQUkgbW9k
>> "!B64TMP!" echo ZWxzLicpCiAgICBhcCgnZWNobyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJ2VjaG8uJykKICAgIGFwKCcnKQogICAg
>> "!B64TMP!" echo IyBEb2NrZXIgY2hlY2sgKGF1dG8tbGF1bmNoIERvY2tlciBEZXNrdG9wIHdoZW4gdGhlIGVuZ2lu
>> "!B64TMP!" echo ZSBpcyBkb3duKQogICAgYXAoJ3doZXJlIGRvY2tlciA+bnVsIDI+JjEnKQogICAgYXAoJ2lmIGVy
>> "!B64TMP!" echo cm9ybGV2ZWwgMSAoJykKICAgIGFwKCcgIGVjaG8gW0VSUk9SXSBEb2NrZXIgd2FzIG5vdCBmb3Vu
>> "!B64TMP!" echo ZCBvbiB5b3VyIFBBVEguJykKICAgIGFwKCcgIGVjaG8gICBJbnN0YWxsIERvY2tlciBEZXNrdG9w
>> "!B64TMP!" echo OiBodHRwczovL3d3dy5kb2NrZXIuY29tL3Byb2R1Y3RzL2RvY2tlci1kZXNrdG9wLycpCiAgICBh
>> "!B64TMP!" echo cCgnICBlY2hvICAgVGhlbiByZS1ydW4gdGhpcyBpbnN0YWxsZXIuJykKICAgIGFwKCcgIHBhdXNl
>> "!B64TMP!" echo ICYgZXhpdCAvYiAxJykKICAgIGFwKCcpJykKICAgIGFwKCdkb2NrZXIgaW5mbyA+bnVsIDI+JjEn
>> "!B64TMP!" echo KQogICAgYXAoJ2lmIG5vdCBlcnJvcmxldmVsIDEgZ290byBkb2NrZXJfb2snKQogICAgYXAoJ2Vj
>> "!B64TMP!" echo aG8gW05PVEVdIFRoZSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5uaW5nIC0gdHJ5aW5nIHRvIHN0
>> "!B64TMP!" echo YXJ0IERvY2tlciBEZXNrdG9wLi4uJykKICAgIGFwKCdzZXQgIkREX0VYRT0iJykKICAgIGFwKCdp
>> "!B64TMP!" echo ZiBleGlzdCAiJVByb2dyYW1GaWxlcyVcXERvY2tlclxcRG9ja2VyXFxEb2NrZXIgRGVza3RvcC5l
>> "!B64TMP!" echo eGUiIHNldCAiRERfRVhFPSVQcm9ncmFtRmlsZXMlXFxEb2NrZXJcXERvY2tlclxcRG9ja2VyIERl
>> "!B64TMP!" echo c2t0b3AuZXhlIicpCiAgICBhcCgnaWYgbm90IGRlZmluZWQgRERfRVhFIGlmIGV4aXN0ICIlUHJv
>> "!B64TMP!" echo Z3JhbUZpbGVzKHg4NiklXFxEb2NrZXJcXERvY2tlclxcRG9ja2VyIERlc2t0b3AuZXhlIiBzZXQg
>> "!B64TMP!" echo IkREX0VYRT0lUHJvZ3JhbUZpbGVzKHg4NiklXFxEb2NrZXJcXERvY2tlclxcRG9ja2VyIERlc2t0
>> "!B64TMP!" echo b3AuZXhlIicpCiAgICBhcCgnaWYgbm90IGRlZmluZWQgRERfRVhFIGlmIGV4aXN0ICIlTE9DQUxB
>> "!B64TMP!" echo UFBEQVRBJVxcUHJvZ3JhbXNcXERvY2tlciBEZXNrdG9wXFxEb2NrZXIgRGVza3RvcC5leGUiIHNl
>> "!B64TMP!" echo dCAiRERfRVhFPSVMT0NBTEFQUERBVEElXFxQcm9ncmFtc1xcRG9ja2VyIERlc2t0b3BcXERvY2tl
>> "!B64TMP!" echo ciBEZXNrdG9wLmV4ZSInKQogICAgYXAoJ2lmIG5vdCBkZWZpbmVkIEREX0VYRSAoJykKICAgIGFw
>> "!B64TMP!" echo KCcgIGVjaG8gW0VSUk9SXSBEb2NrZXIgRGVza3RvcCB3YXMgbm90IGZvdW5kIGluIHRoZSB1c3Vh
>> "!B64TMP!" echo bCBpbnN0YWxsIGxvY2F0aW9ucy4nKQogICAgYXAoJyAgZWNobyAgIFN0YXJ0IGl0IG1hbnVhbGx5
>> "!B64TMP!" echo LCB3YWl0IHVudGlsIGl0IHNheXMgInJ1bm5pbmciLCB0aGVuIHJlLXJ1bicpCiAgICBhcCgnICBl
>> "!B64TMP!" echo Y2hvICAgdGhpcyBpbnN0YWxsZXIuJykKICAgIGFwKCcgIHBhdXNlICYgZXhpdCAvYiAxJykKICAg
>> "!B64TMP!" echo IGFwKCcpJykKICAgIGFwKCdlY2hvICAgICBMYXVuY2hpbmc6ICIhRERfRVhFISInKQogICAgYXAo
>> "!B64TMP!" echo J3N0YXJ0ICIiICIhRERfRVhFISInKQogICAgYXAoJ3NldCAiRERfTEFVTkNIRUQ9MSInKQogICAg
>> "!B64TMP!" echo YXAoJ2VjaG8gICAgIERvY2tlciBEZXNrdG9wIGlzIHN0YXJ0aW5nIGluIHRoZSBiYWNrZ3JvdW5k
>> "!B64TMP!" echo LiBBbnN3ZXIgdGhlIG5leHQnKQogICAgYXAoJ2VjaG8gICAgIHF1ZXN0aW9ucyB3aGlsZSBpdCBi
>> "!B64TMP!" echo b290cyAtIHRoZSBpbnN0YWxsZXIgd2FpdHMgZm9yIHRoZSBlbmdpbmUnKQogICAgYXAoJ2VjaG8g
>> "!B64TMP!" echo ICAgIGJlZm9yZSBwdWxsaW5nIGltYWdlcy4nKQogICAgYXAoJzpkb2NrZXJfb2snKQogICAgYXAo
>> "!B64TMP!" echo J2lmIG5vdCBkZWZpbmVkIEREX0xBVU5DSEVEIGVjaG8gW09LXSBEb2NrZXIgaXMgcnVubmluZy4n
>> "!B64TMP!" echo KQogICAgYXAoJ2VjaG8uJykKICAgIGFwKCcnKQogICAgIyBTb3VyY2UgZm9sZGVyCiAgICBhcCgn
>> "!B64TMP!" echo c2V0ICJTUkM9JX5kcDAiJykKICAgIGFwKCdpZiAiIVNSQzp+LTEhIj09IlxcIiBzZXQgIlNSQz0h
>> "!B64TMP!" echo U1JDOn4wLC0xISInKQogICAgYXAoJycpCiAgICAjIFByb21wdHMKICAgIGFwKCdzZXQgIkRFRkFV
>> "!B64TMP!" echo TFRfVEFSR0VUPSVVU0VSUFJPRklMRSVcXGxvY2FsLXNlYXJjaCInKQogICAgYXAoJycpCiAgICBh
>> "!B64TMP!" echo cCgnZWNobyAtLS0gU3RlcCAxIG9mIDU6IEluc3RhbGwgbG9jYXRpb24gLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0nKQogICAgYXAoJ2VjaG8gICBEZWZhdWx0OiAlREVGQVVMVF9UQVJHRVQlJykK
>> "!B64TMP!" echo ICAgIGFwKCdzZXQgIlRBUkdFVD0iJykKICAgIGFwKCdzZXQgL3AgVEFSR0VUPSIgIFRhcmdldCBm
>> "!B64TMP!" echo b2xkZXIgW3ByZXNzIEVudGVyIGZvciBkZWZhdWx0XTogIicpCiAgICBhcCgnaWYgIiFUQVJHRVQh
>> "!B64TMP!" echo Ij09IiIgc2V0ICJUQVJHRVQ9JURFRkFVTFRfVEFSR0VUJSInKQogICAgYXAoJ3NldCAiVEFSR0VU
>> "!B64TMP!" echo PSFUQVJHRVQ6Ij0hIicpCiAgICBhcCgnZm9yICUlSSBpbiAoIiFUQVJHRVQhIikgZG8gc2V0ICJU
>> "!B64TMP!" echo QVJHRVQ9JSV+ZkkiJykKICAgIGFwKCdlY2hvICAgVXNpbmc6ICFUQVJHRVQhJykKICAgIGFwKCdl
>> "!B64TMP!" echo Y2hvLicpCiAgICBhcCgnJykKICAgIGFwKCc6YXNrX3NlYXJ4bmcnKQogICAgYXAoJ2VjaG8gLS0t
>> "!B64TMP!" echo IFN0ZXAgMiBvZiA1OiBTZWFyWE5HIHBvcnQgKGRlZmF1bHQgOTk5MCkgLS0tLS0tLS0tLS0tLS0n
>> "!B64TMP!" echo KQogICAgYXAoJ3NldCAiU0VBUlhOR19QT1JUPSInKQogICAgYXAoJ3NldCAvcCBTRUFSWE5HX1BP
>> "!B64TMP!" echo UlQ9IiAgUG9ydCBmb3IgU2VhclhORyBbcHJlc3MgRW50ZXIgZm9yIDk5OTBdOiAiJykKICAgIGFw
>> "!B64TMP!" echo KCdpZiAiIVNFQVJYTkdfUE9SVCEiPT0iIiBzZXQgIlNFQVJYTkdfUE9SVD05OTkwIicpCiAgICBh
>> "!B64TMP!" echo cCgnY2FsbCA6dmFsaWRhdGVfcG9ydCAiIVNFQVJYTkdfUE9SVCEiJykKICAgIGFwKCdpZiAhZXJy
>> "!B64TMP!" echo b3JsZXZlbCEgbmVxIDAgKCBlY2hvICAgW1dBUk5JTkddICIhU0VBUlhOR19QT1JUISIgaXMgbm90
>> "!B64TMP!" echo IGEgdmFsaWQgcG9ydCBeKDEtNjU1MzVeKS4gJiBlY2hvLiAmIGdvdG8gYXNrX3NlYXJ4bmcgKScp
>> "!B64TMP!" echo CiAgICBhcCgnJykKICAgIGFwKCc6YXNrX2ZpcmVjcmF3bCcpCiAgICBhcCgnZWNobyAtLS0gU3Rl
>> "!B64TMP!" echo cCAzIG9mIDU6IEZpcmVjcmF3bCBwb3J0IChkZWZhdWx0IDk5OTEpIC0tLS0tLS0tLS0tLScpCiAg
>> "!B64TMP!" echo ICBhcCgnc2V0ICJGSVJFQ1JBV0xfUE9SVD0iJykKICAgIGFwKCdzZXQgL3AgRklSRUNSQVdMX1BP
>> "!B64TMP!" echo UlQ9IiAgUG9ydCBmb3IgRmlyZWNyYXdsIFtwcmVzcyBFbnRlciBmb3IgOTk5MV06ICInKQogICAg
>> "!B64TMP!" echo YXAoJ2lmICIhRklSRUNSQVdMX1BPUlQhIj09IiIgc2V0ICJGSVJFQ1JBV0xfUE9SVD05OTkxIicp
>> "!B64TMP!" echo CiAgICBhcCgnY2FsbCA6dmFsaWRhdGVfcG9ydCAiIUZJUkVDUkFXTF9QT1JUISInKQogICAgYXAo
>> "!B64TMP!" echo J2lmICFlcnJvcmxldmVsISBuZXEgMCAoIGVjaG8gICBbV0FSTklOR10gIiFGSVJFQ1JBV0xfUE9S
>> "!B64TMP!" echo VCEiIGlzIG5vdCBhIHZhbGlkIHBvcnQgXigxLTY1NTM1XikuICYgZWNoby4gJiBnb3RvIGFza19m
>> "!B64TMP!" echo aXJlY3Jhd2wgKScpCiAgICBhcCgnaWYgL2kgIiFGSVJFQ1JBV0xfUE9SVCEiPT0iIVNFQVJYTkdf
>> "!B64TMP!" echo UE9SVCEiICggZWNobyAgIFtXQVJOSU5HXSBGaXJlY3Jhd2wgcG9ydCBtdXN0IGRpZmZlciBmcm9t
>> "!B64TMP!" echo IFNlYXJYTkcgcG9ydC4gJiBlY2hvLiAmIGdvdG8gYXNrX2ZpcmVjcmF3bCApJykKICAgIGFwKCcn
>> "!B64TMP!" echo KQogICAgYXAoJ2VjaG8uJykKICAgIGFwKCdlY2hvIC0tLSBTdGVwIDQgb2YgNTogTG9jYWwgTExN
>> "!B64TMP!" echo IChvcHRpb25hbCkgLS0tLS0tLS0tLS0tLS0tLS0tLS0tJykKICAgIGFwKCdlY2hvICAgTGV0cyBG
>> "!B64TMP!" echo aXJlY3Jhd2wgZG8gQUkgZXh0cmFjdGlvbiAoL3YxL2V4dHJhY3QpIGFuZCBzdW1tYXJpZXMuJykK
>> "!B64TMP!" echo ICAgIGFwKCdlY2hvICAgUmVjb21tZW5kZWQ6IExNIFN0dWRpbyAgLV4+ICBodHRwOi8vbG9jYWxo
>> "!B64TMP!" echo b3N0OjEyMzQvdjEnKQogICAgYXAoJ3NldCAiVVNFX0xMTT0iJykKICAgIGFwKCdzZXQgL3AgVVNF
>> "!B64TMP!" echo X0xMTT0iICBDb25uZWN0IGEgbG9jYWwgTExNIG5vdz8gW3kvTl06ICInKQogICAgYXAoJ3NldCAi
>> "!B64TMP!" echo T1BFTkFJX0JBU0VfVVJMPSInKQogICAgYXAoJ3NldCAiT1BFTkFJX0FQSV9LRVk9IicpCiAgICBh
>> "!B64TMP!" echo cCgnc2V0ICJNT0RFTF9OQU1FPSInKQogICAgYXAoJ2lmIC9pICIhVVNFX0xMTSEiPT0ieSIgKCcp
>> "!B64TMP!" echo CiAgICBhcCgnICBzZXQgIkxMTV9VUkw9IicpCiAgICBhcCgnICBzZXQgL3AgTExNX1VSTD0iICAg
>> "!B64TMP!" echo IExNIFN0dWRpbyBzZXJ2ZXIgVVJMIGFzIHNob3duIGluIExNIFN0dWRpbyBbRW50ZXIgPSBodHRw
>> "!B64TMP!" echo Oi8vbG9jYWxob3N0OjEyMzQvdjFdOiAiJykKICAgIGFwKCcgIGlmICIhTExNX1VSTCEiPT0iIiBz
>> "!B64TMP!" echo ZXQgIkxMTV9VUkw9aHR0cDovL2xvY2FsaG9zdDoxMjM0L3YxIicpCiAgICBhcCgnICBzZXQgIkxM
>> "!B64TMP!" echo TV9NT0RFTD0iJykKICAgIGFwKCcgIHNldCAvcCBMTE1fTU9ERUw9IiAgICBNb2RlbCBuYW1lIGxv
>> "!B64TMP!" echo YWRlZCBpbiBMTSBTdHVkaW8gW0VudGVyIHRvIHNraXBdOiAiJykKICAgIGFwKCcgIHNldCAiT1BF
>> "!B64TMP!" echo TkFJX0JBU0VfVVJMPSFMTE1fVVJMISInKQogICAgYXAoJyAgc2V0ICJPUEVOQUlfQkFTRV9VUkw9
>> "!B64TMP!" echo IU9QRU5BSV9CQVNFX1VSTDpodHRwOi8vbG9jYWxob3N0PWh0dHA6Ly9ob3N0LmRvY2tlci5pbnRl
>> "!B64TMP!" echo cm5hbCEiJykKICAgIGFwKCcgIHNldCAiT1BFTkFJX0JBU0VfVVJMPSFPUEVOQUlfQkFTRV9VUkw6
>> "!B64TMP!" echo aHR0cDovLzEyNy4wLjAuMT1odHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWwhIicpCiAgICBhcCgn
>> "!B64TMP!" echo ICBzZXQgIk9QRU5BSV9BUElfS0VZPWxtLXN0dWRpbyInKQogICAgYXAoJyAgaWYgbm90ICIhTExN
>> "!B64TMP!" echo X01PREVMISI9PSIiIHNldCAiTU9ERUxfTkFNRT0hTExNX01PREVMISInKQogICAgYXAoJyAgZWNo
>> "!B64TMP!" echo byAgICAgXihDb250YWluZXIgd2lsbCByZWFjaCBpdCBhdDogIU9QRU5BSV9CQVNFX1VSTCFeKScp
>> "!B64TMP!" echo CiAgICBhcCgnICBlY2hvICAgICBeKE1ha2Ugc3VyZSBMTSBTdHVkaW8gaGFzICJTZXJ2ZSBvbiBs
>> "!B64TMP!" echo b2NhbCBuZXR3b3JrIiBlbmFibGVkLl4pJykKICAgIGFwKCcpJykKICAgIGFwKCcnKQogICAgIyBT
>> "!B64TMP!" echo dGVwIDU6IG9wdGlvbmFsIEZpcmVjcmF3bCBhY2NvdW50ICh1bmxvY2tzIHRoZSBhY2NvdW50LWdh
>> "!B64TMP!" echo dGVkIHRvb2xzKQogICAgIyBOT1RFOiBldmVyeSBlY2hvIGxpbmUgbXVzdCBjYXJyeSBiYWxhbmNl
>> "!B64TMP!" echo ZCAob3IgXi1lc2NhcGVkKSBwYXJlbnMgLQogICAgIyBhbiB1bmVzY2FwZWQgdW5iYWxhbmNlZCAi
>> "!B64TMP!" echo KCIgbWFrZXMgcmVhbCBjbWQuZXhlIHN3YWxsb3cgdGhlIE5FWFQgbGluZQogICAgIyBhcyBhIGNv
>> "!B64TMP!" echo bnRpbnVhdGlvbiBhbmQgZGllIHdpdGggYSBzeW50YXggZXJyb3IgKHRoZSB3aW5kb3cganVzdCBj
>> "!B64TMP!" echo bG9zZXMpLgogICAgYXAoJ2VjaG8gLS0tIFN0ZXAgNSBvZiA1OiBGaXJlY3Jhd2wgYWNjb3VudCAo
>> "!B64TMP!" echo b3B0aW9uYWwpIC0tLS0tLS0tLS0tLS0nKQogICAgYXAoJ2VjaG8gICBUaGUgZXh0cmEgdG9vbHMg
>> "!B64TMP!" echo XihyZXNlYXJjaCBhZ2VudCwgbGl2ZS1wYWdlIGludGVyYWN0LCBmaWxlIHBhcnNlLCcpCiAgICBh
>> "!B64TMP!" echo cCgnZWNobyAgIG1vbml0b3JzLCBwYXBlciByZXNlYXJjaCwgR2l0SHViL2RldmVsb3BlciBzZWFy
>> "!B64TMP!" echo Y2heKSBvbmx5IHdvcmsnKQogICAgYXAoJ2VjaG8gICB3aXRoIGEgRmlyZWNyYXdsIGFjY291bnQg
>> "!B64TMP!" echo QVBJIGtleSBeKHBhaWQgY2xvdWQgc2VydmljZV4pOicpCiAgICBhcCgnZWNobyAgICAgaHR0cHM6
>> "!B64TMP!" echo Ly93d3cuZmlyZWNyYXdsLmRldicpCiAgICBhcCgnZWNobyAgIEFuc3dlciBOIHRvIGluc3RhbGwg
>> "!B64TMP!" echo b25seSB0aGUgZnJlZSBsb2NhbCB0b29scyBeKGRlZmF1bHReKS4nKQogICAgYXAoJ3NldCAiVVNF
>> "!B64TMP!" echo X0ZDPSInKQogICAgYXAoJ3NldCAvcCBVU0VfRkM9IiAgQWRkIGEgRmlyZWNyYXdsIGFjY291bnQg
>> "!B64TMP!" echo bm93PyBbeS9OXTogIicpCiAgICBhcCgnc2V0ICJGQ19BUElfS0VZPSInKQogICAgYXAoJ3NldCAi
>> "!B64TMP!" echo RkNfQVBJX1VSTD0iJykKICAgIGFwKCdpZiAvaSBub3QgIiFVU0VfRkMhIj09InkiIGdvdG8gZmNf
>> "!B64TMP!" echo ZG9uZScpCiAgICBhcCgnc2V0ICJGQ19UUklFUz0wIicpCiAgICBhcCgnOmFza19mY2tleScpCiAg
>> "!B64TMP!" echo ICBhcCgnc2V0ICJGQ19BUElfS0VZPSInKQogICAgYXAoJ3NldCAvcCBGQ19BUElfS0VZPSIgICAg
>> "!B64TMP!" echo RmlyZWNyYXdsIEFQSSBrZXkgKGZyb20gaHR0cHM6Ly93d3cuZmlyZWNyYXdsLmRldik6ICInKQog
>> "!B64TMP!" echo ICAgYXAoJ2lmIG5vdCAiIUZDX0FQSV9LRVkhIj09IiIgZ290byBmY2tleV9vaycpCiAgICBhcCgn
>> "!B64TMP!" echo c2V0IC9hIEZDX1RSSUVTKz0xJykKICAgIGFwKCdpZiAhRkNfVFJJRVMhIGdlcSAzICgnKQogICAg
>> "!B64TMP!" echo YXAoJyAgZWNobyAgICAgW1dBUk5JTkddIE5vIEFQSSBrZXkgZW50ZXJlZCAtIGNvbnRpbnVpbmcg
>> "!B64TMP!" echo V0lUSE9VVCBhIEZpcmVjcmF3bCBhY2NvdW50LicpCiAgICBhcCgnICBnb3RvIGZjX2RvbmUnKQog
>> "!B64TMP!" echo ICAgYXAoJyknKQogICAgYXAoJ2VjaG8gICAgIFtXQVJOSU5HXSBUaGUgQVBJIGtleSBjYW5ub3Qg
>> "!B64TMP!" echo YmUgZW1wdHkgLSB0cnkgYWdhaW4uJykKICAgIGFwKCdnb3RvIGFza19mY2tleScpCiAgICBhcCgn
>> "!B64TMP!" echo OmZja2V5X29rJykKICAgIGFwKCdzZXQgIkZDX0FQSV9VUkw9IicpCiAgICBhcCgnc2V0IC9wIEZD
>> "!B64TMP!" echo X0FQSV9VUkw9IiAgICBGaXJlY3Jhd2wgQVBJIFVSTCBbcHJlc3MgRW50ZXIgZm9yIGh0dHBzOi8v
>> "!B64TMP!" echo YXBpLmZpcmVjcmF3bC5kZXZdOiAiJykKICAgIGFwKCdpZiAiIUZDX0FQSV9VUkwhIj09IiIgc2V0
>> "!B64TMP!" echo ICJGQ19BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYiJykKICAgIGFwKCc6ZmNfZG9u
>> "!B64TMP!" echo ZScpCiAgICBhcCgnZWNoby4nKQogICAgIyBTdW1tYXJ5ICsgY29uZmlybQogICAgYXAoJ2VjaG8u
>> "!B64TMP!" echo JykKICAgIGFwKCdlY2hvID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnZWNobyAgIFN1bW1hcnknKQogICAgYXAoJ2Vj
>> "!B64TMP!" echo aG8gICBGb2xkZXI6ICAgICAgICAgIVRBUkdFVCEnKQogICAgYXAoJ2VjaG8gICBTZWFyWE5HIHBv
>> "!B64TMP!" echo cnQ6ICAgIVNFQVJYTkdfUE9SVCEnKQogICAgYXAoJ2VjaG8gICBGaXJlY3Jhd2wgcG9ydDogIUZJ
>> "!B64TMP!" echo UkVDUkFXTF9QT1JUIScpCiAgICBhcCgnZWNobyAgIEFnZW50IHNraWxsOiAgICAlVVNFUlBST0ZJ
>> "!B64TMP!" echo TEUlXFwuYWdlbnRzXFxza2lsbHNcXGxvY2FsLXdlYi1zZWFyY2gnKQogICAgYXAoJ2lmIGRlZmlu
>> "!B64TMP!" echo ZWQgT1BFTkFJX0JBU0VfVVJMICgnKQogICAgYXAoJyAgZWNobyAgIExMTSBlbmRwb2ludDogICAh
>> "!B64TMP!" echo T1BFTkFJX0JBU0VfVVJMISAgIU1PREVMX05BTUUhJykKICAgIGFwKCcpIGVsc2UgKCcpCiAgICBh
>> "!B64TMP!" echo cCgnICBlY2hvICAgTExNIGVuZHBvaW50OiAgIF4obm9uZSAtIGVuYWJsZSBsYXRlciBieSBlZGl0
>> "!B64TMP!" echo aW5nIC5lbnZeKScpCiAgICBhcCgnKScpCiAgICBhcCgnaWYgZGVmaW5lZCBGQ19BUElfS0VZICgn
>> "!B64TMP!" echo KQogICAgYXAoJyAgZWNobyAgIEZpcmVjcmF3bCBhY2N0OiAhRkNfQVBJX1VSTCEgIF4oYWNjb3Vu
>> "!B64TMP!" echo dCB0b29scyBpbnN0YWxsZWReKScpCiAgICBhcCgnKSBlbHNlICgnKQogICAgYXAoJyAgZWNobyAg
>> "!B64TMP!" echo IEZpcmVjcmF3bCBhY2N0OiBeKG5vbmUgLSBmcmVlIGxvY2FsIHRvb2xzIG9ubHleKScpCiAgICBh
>> "!B64TMP!" echo cCgnKScpCiAgICBhcCgnZWNobyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJ3NldCAiQ09ORklSTT0iJykKICAgIGFw
>> "!B64TMP!" echo KCdzZXQgL3AgQ09ORklSTT0iUHJvY2VlZCB3aXRoIGluc3RhbGw/IFtZL25dOiAiJykKICAgIGFw
>> "!B64TMP!" echo KCdpZiAvaSAiIUNPTkZJUk0hIj09Im4iICggZWNobyBJbnN0YWxsIGNhbmNlbGxlZC4gJiBwYXVz
>> "!B64TMP!" echo ZSAmIGV4aXQgL2IgMCApJykKICAgIGFwKCcnKQogICAgIyBDcmVhdGUgZm9sZGVycwogICAgYXAo
>> "!B64TMP!" echo J2lmIG5vdCBleGlzdCAiIVRBUkdFVCEiIG1rZGlyICIhVEFSR0VUISInKQogICAgYXAoJ2lmIG5v
>> "!B64TMP!" echo dCBleGlzdCAiIVRBUkdFVCFcXGNvbmZpZ1xcc2VhcnhuZyIgbWtkaXIgIiFUQVJHRVQhXFxjb25m
>> "!B64TMP!" echo aWdcXHNlYXJ4bmciJykKICAgIGFwKCdpZiBub3QgZXhpc3QgIiFUQVJHRVQhXFxsb2NhbC13ZWIt
>> "!B64TMP!" echo c2VhcmNoXFxzY3JpcHRzIiBta2RpciAiIVRBUkdFVCFcXGxvY2FsLXdlYi1zZWFyY2hcXHNjcmlw
>> "!B64TMP!" echo dHMiJykKICAgIGFwKCcnKQogICAgIyBCYWNrdXAgZXhpc3RpbmcgLmVudgogICAgYXAoJ2lmIGV4
>> "!B64TMP!" echo aXN0ICIhVEFSR0VUIVxcLmVudiIgKCcpCiAgICBhcCgnICBmb3IgL2YgInVzZWJhY2txIGRlbGlt
>> "!B64TMP!" echo cz0iICUldCBpbiAoYHBvd2Vyc2hlbGwgLU5vUHJvZmlsZSAtQ29tbWFuZCAiR2V0LURhdGUgLUZv
>> "!B64TMP!" echo cm1hdCB5eXl5TU1kZEhIbW1zcyJgKSBkbyBzZXQgIkxEVD0lJXQiJykKICAgIGFwKCcgIGNvcHkg
>> "!B64TMP!" echo L1kgIiFUQVJHRVQhXFwuZW52IiAiIVRBUkdFVCFcXC5lbnYuYmFrLiFMRFQhIiA+bnVsJykKICAg
>> "!B64TMP!" echo IGFwKCcgIGVjaG8gICBCYWNrZWQgdXAgZXhpc3RpbmcgLmVudiB0byAuZW52LmJhay4hTERUIScp
>> "!B64TMP!" echo CiAgICBhcCgnKScpCiAgICBhcCgnJykKICAgICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAgIyAgTWF0ZXJpYWxp
>> "!B64TMP!" echo c2UgZXZlcnkgcHJvamVjdCBmaWxlOiBjb3B5IGZyb20gc291cmNlIGlmIHByZXNlbnQsIGVsc2UK
>> "!B64TMP!" echo ICAgICMgIGRlY29kZSB0aGUgZW1iZWRkZWQgYmFzZTY0IGJsb2IgZm9yIHRoYXQgZmlsZS4KICAg
>> "!B64TMP!" echo ICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLQogICAgYXAoJ2VjaG8gQ29weWluZyBmaWxlcy4uLicpCgogICAgZm9yIHJl
>> "!B64TMP!" echo bCwgc3JjIGluIEZJTEVTOgogICAgICAgIGlmIHJlbCA9PSAiaW5zdGFsbC1sb2NhbC1zZWFyY2gu
>> "!B64TMP!" echo YmF0IjoKICAgICAgICAgICAgIyBUaGUgLmJhdCBjb3BpZXMgSVRTRUxGIGF0IHJ1bnRpbWUgdmlh
>> "!B64TMP!" echo ICV+ZjAgKHNlZSBiZWxvdykuIERvIG5vdAogICAgICAgICAgICAjIGVtYmVkIGl0c2VsZiBoZXJl
>> "!B64TMP!" echo IC0tIHRoYXQgd291bGQgcmVhZCBhIHN0YWxlIHByZXZpb3VzLWdlbmVyYXRpb24KICAgICAgICAg
>> "!B64TMP!" echo ICAgIyAuYmF0IGFuZCBjcmVhdGUgYSBjb25mdXNpbmcgZHVwbGljYXRlLgogICAgICAgICAgICBj
>> "!B64TMP!" echo b250aW51ZQogICAgICAgIGRhdGEgPSByZWFkKHNyYykKICAgICAgICBsaW5lcyA9IGI2NF9jaHVu
>> "!B64TMP!" echo a2VkKGRhdGEpCiAgICAgICAgcmVsX3dpbiA9IHJlbC5yZXBsYWNlKCIvIiwgIlxcIikKICAgICAg
>> "!B64TMP!" echo ICBhcCgnJykKICAgICAgICBhcCgnUkVNIC0tLSAnICsgcmVsICsgJyAtLS0nKQogICAgICAgIGFw
>> "!B64TMP!" echo KCdzZXQgIk5FRURfQjY0PTEiJykKICAgICAgICBhcCgnaWYgZXhpc3QgIiFTUkMhXFwnICsgcmVs
>> "!B64TMP!" echo X3dpbiArICciICgnKQogICAgICAgIGFwKCcgIGNvcHkgL1kgIiFTUkMhXFwnICsgcmVsX3dpbiAr
>> "!B64TMP!" echo ICciICIhVEFSR0VUIVxcJyArIHJlbF93aW4gKyAnIiA+bnVsIDI+JjEnKQogICAgICAgIGFwKCcg
>> "!B64TMP!" echo IGlmIGV4aXN0ICIhVEFSR0VUIVxcJyArIHJlbF93aW4gKyAnIiBzZXQgIk5FRURfQjY0PTAiJykK
>> "!B64TMP!" echo ICAgICAgICBhcCgnKScpCiAgICAgICAgYXAoJ2lmICIhTkVFRF9CNjQhIj09IjEiICgnKQogICAg
>> "!B64TMP!" echo ICAgIGFwKCcgIGVjaG8gICBbZW1iZWRkZWRdICcgKyByZWwgKyAnICBeKHNvdXJjZSBub3QgZm91
>> "!B64TMP!" echo bmQgbmV4dCB0byBpbnN0YWxsZXI7IHVzaW5nIGJ1aWx0LWluIGNvcHleKScpCiAgICAgICAgIyBE
>> "!B64TMP!" echo ZXRlcm1pbmlzdGljIHRlbXAtZmlsZSB0YWcgZGVyaXZlZCBmcm9tIHRoZSBmaWxlIHBhdGggKENS
>> "!B64TMP!" echo QzMyKS4KICAgICAgICAjIE11c3QgYmUgc3RhYmxlIGFjcm9zcyBnZW4gcnVucyBzbyB0aGUgLmJh
>> "!B64TMP!" echo dCBlbWJlZGRlZCBpbnNpZGUgdGhlIC5zaAogICAgICAgICMgbWF0Y2hlcyB0aGUgc3RhbmRhbG9u
>> "!B64TMP!" echo ZSAuYmF0IGJ5dGUtZm9yLWJ5dGUuCiAgICAgICAgaW1wb3J0IHpsaWIKICAgICAgICB0YWcgPSAi
>> "!B64TMP!" echo TFMiICsgc3RyKHpsaWIuY3JjMzIocmVsLmVuY29kZSgidXRmLTgiKSkgJiAweEZGRkZGRkZGKQog
>> "!B64TMP!" echo ICAgICAgIGFwKCcgIHNldCAiQjY0VE1QPSVURU1QJVxcJyArIHRhZyArICcuYjY0IicpCiAgICAg
>> "!B64TMP!" echo ICAgZmlyc3QgPSBUcnVlCiAgICAgICAgZm9yIGxuIGluIGxpbmVzOgogICAgICAgICAgICBvcCA9
>> "!B64TMP!" echo ICc+JyBpZiBmaXJzdCBlbHNlICc+PicKICAgICAgICAgICAgYXAoJyAgJyArIG9wICsgJyAiIUI2
>> "!B64TMP!" echo NFRNUCEiIGVjaG8gJyArIGxuKQogICAgICAgICAgICBmaXJzdCA9IEZhbHNlCiAgICAgICAgYXAo
>> "!B64TMP!" echo JyAgc2V0ICJMU19CNjRfSU49IUI2NFRNUCEiJykKICAgICAgICBhcCgnICBzZXQgIkxTX0I2NF9P
>> "!B64TMP!" echo VVQ9IVRBUkdFVCFcXCcgKyByZWxfd2luICsgJyInKQogICAgICAgIGFwKCcgIGNhbGwgOmRlY29k
>> "!B64TMP!" echo ZV9iNjQnKQogICAgICAgIGFwKCcgIGlmIGV4aXN0ICIhQjY0VE1QISIgZGVsIC9RICIhQjY0VE1Q
>> "!B64TMP!" echo ISIgPm51bCAyPiYxJykKICAgICAgICBhcCgnKScpCgogICAgIyBJbmNsdWRlIHRoZSBpbnN0YWxs
>> "!B64TMP!" echo ZXJzIHRoZW1zZWx2ZXMgc28gdGhlIGZvbGRlciBpcyBzZWxmLWNvbnRhaW5lZCAvIHJlLWluc3Rh
>> "!B64TMP!" echo bGxhYmxlCiAgICBhcCgnaWYgZXhpc3QgIiFTUkMhXFxpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQi
>> "!B64TMP!" echo IGNvcHkgL1kgIiFTUkMhXFxpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQiICIhVEFSR0VUIVxcaW5z
>> "!B64TMP!" echo dGFsbC1sb2NhbC1zZWFyY2guYmF0IiA+bnVsIDI+JjEnKQogICAgYXAoJ2lmIGV4aXN0ICIhU1JD
>> "!B64TMP!" echo IVxcaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giICBjb3B5IC9ZICIhU1JDIVxcaW5zdGFsbC1sb2Nh
>> "!B64TMP!" echo bC1zZWFyY2guc2giICAiIVRBUkdFVCFcXGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIiAgPm51bCAy
>> "!B64TMP!" echo PiYxJykKICAgIGFwKCdSRU0gQWx3YXlzIGFsc28gZHJvcCB0aGUgKmN1cnJlbnQqIGluc3RhbGxl
>> "!B64TMP!" echo ciAodGhpcyBzY3JpcHQpIGludG8gdGFyZ2V0LCBldmVuIGlmJykKICAgIGFwKCdSRU0gdGhlIHNv
>> "!B64TMP!" echo dXJjZSBjb3B5IGFib3ZlIHdhcyBza2lwcGVkIChlLmcuIHVzZXIgcmFuIGEgcmVuYW1lZCBjb3B5
>> "!B64TMP!" echo IG9mIHRoZSBiYXQpLicpCiAgICBhcCgnY29weSAvWSAiJX5mMCIgIiFUQVJHRVQhXFxpbnN0YWxs
>> "!B64TMP!" echo LWxvY2FsLXNlYXJjaC5iYXQiID5udWwgMj4mMScpCiAgICBhcCgnJykKICAgICMgR2VuZXJhdGUg
>> "!B64TMP!" echo c2VjcmV0cwogICAgYXAoJ2VjaG8gR2VuZXJhdGluZyBzZWN1cmUgY3JlZGVudGlhbHMuLi4nKQog
>> "!B64TMP!" echo ICAgYXAoJ2NhbGwgOmdlbmtleSBTRUNSRVQnKQogICAgYXAoJ2NhbGwgOmdlbmtleSBCVUxMJykK
>> "!B64TMP!" echo ICAgIGFwKCdjYWxsIDpnZW5rZXkgUEdQQVNTJykKICAgIGFwKCdjYWxsIDpnZW5rZXkgUkFCUEFT
>> "!B64TMP!" echo UycpCiAgICBhcCgnJykKICAgICMgV3JpdGUgLmVudgogICAgYXAoJ2VjaG8gV3JpdGluZyAuZW52
>> "!B64TMP!" echo IC4uLicpCiAgICBhcCgnPiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8gIyBMb2NhbCBTZWFyY2ggY29u
>> "!B64TMP!" echo ZmlndXJhdGlvbiAtIGdlbmVyYXRlZCBieSBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQnKQogICAg
>> "!B64TMP!" echo YXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyAjIEVkaXQgcG9ydHMvTExNIGhlcmUsIHRoZW4g
>> "!B64TMP!" echo cnVuIFVwZGF0ZS5iYXQgdG8gYXBwbHkuJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYiIGVj
>> "!B64TMP!" echo aG8uJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8gIyAtLS0tIEhvc3QgcG9ydHMg
>> "!B64TMP!" echo LS0tLScpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvIFNFQVJYTkdfUE9SVD0hU0VB
>> "!B64TMP!" echo UlhOR19QT1JUIScpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvIEZJUkVDUkFXTF9Q
>> "!B64TMP!" echo T1JUPSFGSVJFQ1JBV0xfUE9SVCEnKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNoby4n
>> "!B64TMP!" echo KQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyAjIC0tLS0gU2VhclhORyBpbnN0YW5j
>> "!B64TMP!" echo ZSBzZWNyZXQgLS0tLScpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvIFNFQVJYTkdf
>> "!B64TMP!" echo U0VDUkVUPSFTRUNSRVQhJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8uJykKICAg
>> "!B64TMP!" echo IGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8gIyAtLS0tIEZpcmVjcmF3bCBpbnRlcm5hbCBj
>> "!B64TMP!" echo cmVkZW50aWFscyAtLS0tJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8gQlVMTF9B
>> "!B64TMP!" echo VVRIX0tFWT0hQlVMTCEnKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyBQT1NUR1JF
>> "!B64TMP!" echo U19EQj1maXJlY3Jhd2wnKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyBQT1NUR1JF
>> "!B64TMP!" echo U19VU0VSPWZpcmVjcmF3bCcpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvIFBPU1RH
>> "!B64TMP!" echo UkVTX1BBU1NXT1JEPSFQR1BBU1MhJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8g
>> "!B64TMP!" echo UkFCQklUTVFfVVNFUj1maXJlY3Jhd2wnKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNo
>> "!B64TMP!" echo byBSQUJCSVRNUV9QQVNTV09SRD0hUkFCUEFTUyEnKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVu
>> "!B64TMP!" echo diIgZWNoby4nKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyBMT0dHSU5HX0xFVkVM
>> "!B64TMP!" echo PWluZm8nKQogICAgYXAoJ2lmIGRlZmluZWQgT1BFTkFJX0JBU0VfVVJMICgnKQogICAgYXAoJyAg
>> "!B64TMP!" echo Pj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvLicpCiAgICBhcCgnICA+PiAiIVRBUkdFVCFcXC5lbnYi
>> "!B64TMP!" echo IGVjaG8gIyAtLS0tIExvY2FsIExMTSBmb3IgRmlyZWNyYXdsIEFJIGZlYXR1cmVzIC0tLS0nKQog
>> "!B64TMP!" echo ICAgYXAoJyAgPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvIE9QRU5BSV9CQVNFX1VSTD0hT1BFTkFJ
>> "!B64TMP!" echo X0JBU0VfVVJMIScpCiAgICBhcCgnICA+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8gT1BFTkFJX0FQ
>> "!B64TMP!" echo SV9LRVk9IU9QRU5BSV9BUElfS0VZIScpCiAgICBhcCgnICBpZiBkZWZpbmVkIE1PREVMX05BTUUg
>> "!B64TMP!" echo Pj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvIE1PREVMX05BTUU9IU1PREVMX05BTUUhJykKICAgIGFw
>> "!B64TMP!" echo KCcpJykKICAgIGFwKCdpZiBkZWZpbmVkIEZDX0FQSV9LRVkgKCcpCiAgICBhcCgnICA+PiAiIVRB
>> "!B64TMP!" echo UkdFVCFcXC5lbnYiIGVjaG8uJykKICAgICMgTk9URTogdGhpcyBlY2hvIGxpbmUgbGl2ZXMgSU5T
>> "!B64TMP!" echo SURFIHRoZSBgaWYgZGVmaW5lZCBGQ19BUElfS0VZICggLi4uIClgCiAgICAjIGJsb2NrLiBJbiBj
>> "!B64TMP!" echo bWQgYmxvY2sgcGFyc2luZywgYW4gdW5xdW90ZWQvdW5lc2NhcGVkICIpIiBpbiBlY2hvIHRleHQK
>> "!B64TMP!" echo ICAgICMgQ0xPU0VTIFRIRSBCTE9DSyBFQVJMWSAoICIoIiBpbiB0ZXh0IGlzIGluZXJ0LCAiKSIg
>> "!B64TMP!" echo aXMgc3RydWN0dXJhbCApLAogICAgIyBzbyAiKGNsb3VkIEFQSSkiIHdvdWxkIGVuZCB0aGUgYmxv
>> "!B64TMP!" echo Y2sgYXQgIkFQSSkiIGFuZCB0aGUgcmVzdCBvZiB0aGUKICAgICMgbGluZSBiZWNvbWVzIGEgdG9w
>> "!B64TMP!" echo LWxldmVsIGNvbW1hbmQgLT4gIkZPUiB3YXMgdW5leHBlY3RlZCBhdCB0aGlzIHRpbWUiCiAgICAj
>> "!B64TMP!" echo IC0+IHJlYWwgY21kLmV4ZSBhYm9ydHMgdGhlIHdob2xlIGluc3RhbGxlci4gRXNjYXBlIGJvdGgg
>> "!B64TMP!" echo cGFyZW5zLgogICAgYXAoJyAgPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvICMgLS0tLSBGaXJlY3Jh
>> "!B64TMP!" echo d2wgYWNjb3VudCBeKGNsb3VkIEFQSV4pIGZvciBhY2NvdW50LW9ubHkgdG9vbHMgLS0tLScpCiAg
>> "!B64TMP!" echo ICBhcCgnICA+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8gRklSRUNSQVdMX0FQSV9VUkw9IUZDX0FQ
>> "!B64TMP!" echo SV9VUkwhJykKICAgIGFwKCcgID4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyBGSVJFQ1JBV0xfQVBJ
>> "!B64TMP!" echo X0tFWT0hRkNfQVBJX0tFWSEnKQogICAgYXAoJyknKQogICAgYXAoJycpCiAgICAjIEluamVjdCBT
>> "!B64TMP!" echo ZWFyWE5HIHNlY3JldCBpbnRvIHNldHRpbmdzLnltbAogICAgYXAoJ2VjaG8gSW5qZWN0aW5nIFNl
>> "!B64TMP!" echo YXJYTkcgc2VjcmV0IGludG8gc2V0dGluZ3MueW1sIC4uLicpCiAgICBhcCgncG93ZXJzaGVsbCAt
>> "!B64TMP!" echo Tm9Qcm9maWxlIC1Db21tYW5kICIoR2V0LUNvbnRlbnQgLVJhdyBcJyFUQVJHRVQhXFxjb25maWdc
>> "!B64TMP!" echo XHNlYXJ4bmdcXHNldHRpbmdzLnltbFwnKSAtcmVwbGFjZSBcJ19fU0VBUlhOR19TRUNSRVRfUExB
>> "!B64TMP!" echo Q0VIT0xERVJfX1wnLCBcJyFTRUNSRVQhXCcgfCBTZXQtQ29udGVudCAtTm9OZXdsaW5lIFwnIVRB
>> "!B64TMP!" echo UkdFVCFcXGNvbmZpZ1xcc2VhcnhuZ1xcc2V0dGluZ3MueW1sXCciJykKICAgIGFwKCcnKQogICAg
>> "!B64TMP!" echo IyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tCiAgICAjICBDb3JlLW9ubHkgdHJpbTogd2l0aG91dCBhIEZpcmVjcmF3bCBh
>> "!B64TMP!" echo Y2NvdW50LCByZW1vdmUgdGhlIDE5CiAgICAjICBhY2NvdW50LWdhdGVkIHNjcmlwdHMgZnJvbSB0
>> "!B64TMP!" echo aGUgYnVuZGxlZCBza2lsbCBhbmQgc3dhcCBpbiB0aGUKICAgICMgIGNvcmUtb25seSBTS0lMTC5t
>> "!B64TMP!" echo ZCBzbyB0aGUgaW5zdGFsbGVkIHNraWxsIG1hdGNoZXMgd2hhdCB3b3Jrcy4KICAgICMgLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLQogICAgYXAoJ2lmIGRlZmluZWQgRkNfQVBJX0tFWSBnb3RvIHNraWxsX2Z1bGwnKQogICAg
>> "!B64TMP!" echo YXAoJ2VjaG8gSW5zdGFsbGluZyB0aGUgY29yZS1vbmx5IGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwg
>> "!B64TMP!" echo KG5vIEZpcmVjcmF3bCBhY2NvdW50KS4uLicpCiAgICBmb3IgbmFtZSBpbiBBQ0NPVU5UX1RPT0xT
>> "!B64TMP!" echo OgogICAgICAgIHJlbF93aW4gPSAibG9jYWwtd2ViLXNlYXJjaFxcc2NyaXB0c1xcIiArIG5hbWUK
>> "!B64TMP!" echo ICAgICAgICBhcCgnaWYgZXhpc3QgIiFUQVJHRVQhXFwnICsgcmVsX3dpbiArICciIGRlbCAvUSAi
>> "!B64TMP!" echo IVRBUkdFVCFcXCcgKyByZWxfd2luICsgJyIgPm51bCAyPiYxJykKICAgIGFwKCdpZiBleGlzdCAi
>> "!B64TMP!" echo IVRBUkdFVCFcXGxvY2FsLXdlYi1zZWFyY2hcXFNLSUxMLWNvcmUubWQiIGNvcHkgL1kgIiFUQVJH
>> "!B64TMP!" echo RVQhXFxsb2NhbC13ZWItc2VhcmNoXFxTS0lMTC1jb3JlLm1kIiAiIVRBUkdFVCFcXGxvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2hcXFNLSUxMLm1kIiA+bnVsJykKICAgIGFwKCc6c2tpbGxfZnVsbCcpCiAgICBhcCgn
>> "!B64TMP!" echo UkVNIFNLSUxMLWNvcmUubWQgaXMgYSBidWlsZC10aW1lIHZhcmlhbnQgLSBuZXZlciBwYXJ0IG9m
>> "!B64TMP!" echo IGFuIGluc3RhbGxlZCBza2lsbC4nKQogICAgYXAoJ2lmIGV4aXN0ICIhVEFSR0VUIVxcbG9jYWwt
>> "!B64TMP!" echo d2ViLXNlYXJjaFxcU0tJTEwtY29yZS5tZCIgZGVsIC9RICIhVEFSR0VUIVxcbG9jYWwtd2ViLXNl
>> "!B64TMP!" echo YXJjaFxcU0tJTEwtY29yZS5tZCIgPm51bCAyPiYxJykKICAgIGFwKCcnKQogICAgIyAtLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tCiAgICAjICBJbnN0YWxsIHRoZSBidW5kbGVkIGxvY2FsLXdlYi1zZWFyY2ggYWdlbnQgc2tp
>> "!B64TMP!" echo bGwgaW50byB0aGUgdXNlcidzIHNraWxscwogICAgIyAgZGlyZWN0b3J5IChhZGQvb3ZlcnJpZGUp
>> "!B64TMP!" echo LCBhbmQgcmVjb3JkIHRoZSBpbnN0YWxsIHBhdGggaGludC4KICAgICMgLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAg
>> "!B64TMP!" echo YXAoJ2VjaG8gSW5zdGFsbGluZyB0aGUgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCBza2lsbC4uLicp
>> "!B64TMP!" echo CiAgICBhcCgnc2V0ICJTS0lMTF9ESVI9JVVTRVJQUk9GSUxFJVxcLmFnZW50c1xcc2tpbGxzXFxs
>> "!B64TMP!" echo b2NhbC13ZWItc2VhcmNoIicpCiAgICBhcCgnaWYgZXhpc3QgIiFTS0lMTF9ESVIhIiByZCAvcyAv
>> "!B64TMP!" echo cSAiIVNLSUxMX0RJUiEiJykKICAgIGFwKCdpZiBub3QgZXhpc3QgIiVVU0VSUFJPRklMRSVcXC5h
>> "!B64TMP!" echo Z2VudHNcXHNraWxscyIgbWtkaXIgIiVVU0VSUFJPRklMRSVcXC5hZ2VudHNcXHNraWxscyInKQog
>> "!B64TMP!" echo ICAgYXAoJ3hjb3B5IC9FIC9JIC9ZIC9RICIhVEFSR0VUIVxcbG9jYWwtd2ViLXNlYXJjaCIgIiFT
>> "!B64TMP!" echo S0lMTF9ESVIhIiA+bnVsJykKICAgIGFwKCdpZiBlcnJvcmxldmVsIDEgKCcpCiAgICBhcCgnICBl
>> "!B64TMP!" echo Y2hvICAgW1dBUk5JTkddIENvdWxkIG5vdCBjb3B5IHRoZSBsb2NhbC13ZWItc2VhcmNoIHNraWxs
>> "!B64TMP!" echo IHRvICFTS0lMTF9ESVIhLicpCiAgICBhcCgnKSBlbHNlICgnKQogICAgYXAoJyAgPiAiIVRBUkdF
>> "!B64TMP!" echo VCFcXGxvY2FsLXdlYi1zZWFyY2hcXGluc3RhbGwtZGlyLnR4dCIgZWNobyAhVEFSR0VUIScpCiAg
>> "!B64TMP!" echo ICBhcCgnICA+ICIhU0tJTExfRElSIVxcaW5zdGFsbC1kaXIudHh0IiBlY2hvICFUQVJHRVQhJykK
>> "!B64TMP!" echo ICAgIGFwKCcgIGVjaG8gICBBZ2VudCBza2lsbCBpbnN0YWxsZWQ6ICFTS0lMTF9ESVIhJykKICAg
>> "!B64TMP!" echo IGFwKCcpJykKICAgIGFwKCcnKQogICAgIyBXYWl0IGZvciB0aGUgZW5naW5lIGlmIHdlIGxhdW5j
>> "!B64TMP!" echo aGVkIERvY2tlciBEZXNrdG9wIGVhcmxpZXIgKHRoZSBwcm9tcHRzCiAgICAjIGFib3ZlIHJhbiB3
>> "!B64TMP!" echo aGlsZSBpdCB3YXMgYm9vdGluZyBpbiB0aGUgYmFja2dyb3VuZCkuCiAgICBhcCgnUkVNIEhvdyBs
>> "!B64TMP!" echo b25nIHRvIHdhaXQgZm9yIGEganVzdC1sYXVuY2hlZCBEb2NrZXIgZW5naW5lIHRvIGNvbWUgb25s
>> "!B64TMP!" echo aW5lIChzZWNvbmRzKS4nKQogICAgYXAoJ3NldCAiRERfVElNRU9VVD0zMDAiJykKICAgIGFwKCdp
>> "!B64TMP!" echo ZiBkZWZpbmVkIExPQ0FMX1NFQVJDSF9ET0NLRVJfVElNRU9VVCBzZXQgIkREX1RJTUVPVVQ9IUxP
>> "!B64TMP!" echo Q0FMX1NFQVJDSF9ET0NLRVJfVElNRU9VVCEiJykKICAgIGFwKCdpZiBub3QgZGVmaW5lZCBERF9M
>> "!B64TMP!" echo QVVOQ0hFRCBnb3RvIGRvY2tlcl9lbmdpbmVfcmVhZHknKQogICAgYXAoJ2VjaG8gV2FpdGluZyBm
>> "!B64TMP!" echo b3IgdGhlIERvY2tlciBlbmdpbmUgdG8gY29tZSBvbmxpbmUgLSB1cCB0byAhRERfVElNRU9VVCEg
>> "!B64TMP!" echo c2Vjb25kcy4uLicpCiAgICBhcCgnc2V0IC9hIEREX1dBSVQ9MCcpCiAgICBhcCgnOmRvY2tlcl93
>> "!B64TMP!" echo YWl0JykKICAgIGFwKCd0aW1lb3V0IC90IDUgL25vYnJlYWsgPm51bCAyPiYxJykKICAgIGFwKCdp
>> "!B64TMP!" echo ZiBlcnJvcmxldmVsIDEgcGluZyAtbiA2IDEyNy4wLjAuMSA+bnVsIDI+JjEnKQogICAgYXAoJ3Nl
>> "!B64TMP!" echo dCAvYSBERF9XQUlUKz01JykKICAgIGFwKCdkb2NrZXIgaW5mbyA+bnVsIDI+JjEnKQogICAgYXAo
>> "!B64TMP!" echo J2lmIG5vdCBlcnJvcmxldmVsIDEgZ290byBkb2NrZXJfZW5naW5lX3JlYWR5JykKICAgIGFwKCdp
>> "!B64TMP!" echo ZiAhRERfV0FJVCEgZ2VxICFERF9USU1FT1VUISAoJykKICAgIGFwKCcgIGVjaG8gW0VSUk9SXSBU
>> "!B64TMP!" echo aGUgRG9ja2VyIGVuZ2luZSBkaWQgbm90IGNvbWUgb25saW5lIHdpdGhpbiAhRERfVElNRU9VVCEg
>> "!B64TMP!" echo c2Vjb25kcy4nKQogICAgYXAoJyAgZWNobyAgIENoZWNrIERvY2tlciBEZXNrdG9wIGZvciBlcnJv
>> "!B64TMP!" echo cnMsIHdhaXQgdW50aWwgaXQgc2F5cyAicnVubmluZyIsJykKICAgIGFwKCcgIGVjaG8gICB0aGVu
>> "!B64TMP!" echo IHJlLXJ1biB0aGlzIGluc3RhbGxlci4nKQogICAgYXAoJyAgcGF1c2UgJiBleGl0IC9iIDEnKQog
>> "!B64TMP!" echo ICAgYXAoJyknKQogICAgYXAoJ3NldCAvYSAiRERfTU9EPUREX1dBSVQgJSUgMTUiJykKICAgIGFw
>> "!B64TMP!" echo KCdpZiAhRERfTU9EISBlcXUgMCBlY2hvICAgICAuLi4gc3RpbGwgd2FpdGluZyAhRERfV0FJVCFz
>> "!B64TMP!" echo JykKICAgIGFwKCdnb3RvIGRvY2tlcl93YWl0JykKICAgIGFwKCc6ZG9ja2VyX2VuZ2luZV9yZWFk
>> "!B64TMP!" echo eScpCiAgICBhcCgnaWYgZGVmaW5lZCBERF9MQVVOQ0hFRCBlY2hvIFtPS10gRG9ja2VyIGVuZ2lu
>> "!B64TMP!" echo ZSBpcyBvbmxpbmUgYWZ0ZXIgIUREX1dBSVQhcy4nKQogICAgYXAoJycpCiAgICAjIFB1bGwgKyB1
>> "!B64TMP!" echo cAogICAgYXAoJ2VjaG8uJykKICAgIGFwKCdlY2hvIFB1bGxpbmcgRG9ja2VyIGltYWdlcyAoZmly
>> "!B64TMP!" echo c3QgcnVuIGRvd25sb2FkcyB+My00IEdCLCBwbGVhc2UgYmUgcGF0aWVudCkuLi4nKQogICAgYXAo
>> "!B64TMP!" echo J3B1c2hkICIhVEFSR0VUISInKQogICAgYXAoJ2RvY2tlciBjb21wb3NlIHB1bGwnKQogICAgYXAo
>> "!B64TMP!" echo J2lmICFlcnJvcmxldmVsISBuZXEgMCAoIGVjaG8gICBbV0FSTklOR10gZG9ja2VyIGNvbXBvc2Ug
>> "!B64TMP!" echo cHVsbCByZXBvcnRlZCBlcnJvcnMuIFRyeWluZyB0byBzdGFydCBhbnl3YXkuLi4gKScpCiAgICBh
>> "!B64TMP!" echo cCgnZWNobyBTdGFydGluZyBzZXJ2aWNlcy4uLicpCiAgICBhcCgnZG9ja2VyIGNvbXBvc2UgdXAg
>> "!B64TMP!" echo LWQnKQogICAgYXAoJ3NldCAiVVBfUkM9IWVycm9ybGV2ZWwhIicpCiAgICBhcCgncG9wZCcpCiAg
>> "!B64TMP!" echo ICBhcCgnaWYgIVVQX1JDISBuZXEgMCAoJykKICAgIGFwKCcgIGVjaG8uJykKICAgIGFwKCcgIGVj
>> "!B64TMP!" echo aG8gW0VSUk9SXSBkb2NrZXIgY29tcG9zZSB1cCBmYWlsZWQuIFNlZSBtZXNzYWdlcyBhYm92ZS4n
>> "!B64TMP!" echo KQogICAgYXAoJyAgZWNobyAgIENvbW1vbiBmaXhlczonKQogICAgYXAoJyAgZWNobyAgICAgLSBN
>> "!B64TMP!" echo YWtlIHN1cmUgRG9ja2VyIERlc2t0b3AgaXMgcnVubmluZy4nKQogICAgYXAoJyAgZWNobyAgICAg
>> "!B64TMP!" echo LSBNYWtlIHN1cmUgcG9ydHMgIVNFQVJYTkdfUE9SVCEgYW5kICFGSVJFQ1JBV0xfUE9SVCEgYXJl
>> "!B64TMP!" echo IG5vdCBpbiB1c2UuJykKICAgIGFwKCcgIGVjaG8gICAgIC0gUmUtcnVuIHRoaXMgaW5zdGFsbGVy
>> "!B64TMP!" echo IG9yIHJ1biBVcGRhdGUuYmF0IGFmdGVyIGZpeGluZy4nKQogICAgYXAoJyAgZWNoby4nKQogICAg
>> "!B64TMP!" echo YXAoJyAgcGF1c2UgJiBleGl0IC9iIDEnKQogICAgYXAoJyknKQogICAgYXAoJycpCiAgICAjIERv
>> "!B64TMP!" echo bmUKICAgIGFwKCdlY2hvLicpCiAgICBhcCgnZWNobyA9PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJ2VjaG8gICBJbnN0
>> "!B64TMP!" echo YWxsYXRpb24gY29tcGxldGUhJykKICAgIGFwKCdlY2hvLicpCiAgICBhcCgnZWNobyAgIFNlYXJY
>> "!B64TMP!" echo TkcgIChzZWFyY2ggKyBKU09OIEFQSSk6ICBodHRwOi8vbG9jYWxob3N0OiFTRUFSWE5HX1BPUlQh
>> "!B64TMP!" echo JykKICAgIGFwKCdlY2hvICAgRmlyZWNyYXdsIChzY3JhcGUvY3Jhd2wgQVBJKTogaHR0cDovL2xv
>> "!B64TMP!" echo Y2FsaG9zdDohRklSRUNSQVdMX1BPUlQhJykKICAgIGFwKCdlY2hvICAgbG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aCBza2lsbDogICAgICAgICAgICAgICVVU0VSUFJPRklMRSVcXC5hZ2VudHNcXHNraWxsc1xcbG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaCcpCiAgICBhcCgnZWNoby4nKQogICAgYXAoJ2VjaG8gICBJZiB5b3VyIGFn
>> "!B64TMP!" echo ZW50IHdhcyBhbHJlYWR5IHJ1bm5pbmcsIHJlc3RhcnQgaXQgc28gaXQgcGlja3MgdXAnKQogICAg
>> "!B64TMP!" echo YXAoJ2VjaG8gICB0aGUgbmV3IHNraWxsLicpCiAgICBhcCgnZWNoby4nKQogICAgYXAoJ2VjaG8g
>> "!B64TMP!" echo ICBNYW5hZ2UgdGhlIHN0YWNrIHdpdGggdGhlIC5iYXQgZmlsZXMgaW46JykKICAgIGFwKCdlY2hv
>> "!B64TMP!" echo ICAgICAhVEFSR0VUIScpCiAgICBhcCgnZWNobyAgICAgICBSdW4uYmF0ICAgU3RvcC5iYXQgICBV
>> "!B64TMP!" echo cGRhdGUuYmF0ICAgVW5pbnN0YWxsLmJhdCcpCiAgICBhcCgnZWNoby4nKQogICAgYXAoJ2VjaG8g
>> "!B64TMP!" echo ICBTZWUgUkVBRE1FLm1kIGZvciBob3cgdG8gY29ubmVjdCB0aGlzIHRvIHlvdXIgQUkgbW9kZWxz
>> "!B64TMP!" echo JykKICAgIGFwKCdlY2hvICAgKGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwsIExNIFN0dWRpbywgTUNQ
>> "!B64TMP!" echo IHNlcnZlciwgZGlyZWN0IHByb21wdGluZywgZXRjLikuJykKICAgIGFwKCdlY2hvID09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAg
>> "!B64TMP!" echo ICBhcCgnZWNoby4nKQogICAgYXAoJ3BhdXNlJykKICAgIGFwKCdleGl0IC9iIDAnKQogICAgYXAo
>> "!B64TMP!" echo JycpCiAgICAjIFN1YnJvdXRpbmVzCiAgICBhcCgnUkVNID09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAg
>> "!B64TMP!" echo ICBhcCgnUkVNICBTdWJyb3V0aW5lcycpCiAgICBhcCgnUkVNID09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScp
>> "!B64TMP!" echo CiAgICBhcCgnJykKICAgIGFwKCc6dmFsaWRhdGVfcG9ydCcpCiAgICBhcCgnZWNobyAlfjF8IGZp
>> "!B64TMP!" echo bmRzdHIgL3IgL2M6Il5bMC05XVswLTldKiQiID5udWwnKQogICAgYXAoJ2lmIGVycm9ybGV2ZWwg
>> "!B64TMP!" echo MSBleGl0IC9iIDEnKQogICAgYXAoJ2lmICV+MSBsc3MgMSBleGl0IC9iIDEnKQogICAgYXAoJ2lm
>> "!B64TMP!" echo ICV+MSBndHIgNjU1MzUgZXhpdCAvYiAxJykKICAgIGFwKCdleGl0IC9iIDAnKQogICAgYXAoJycp
>> "!B64TMP!" echo CiAgICBhcCgnOmdlbmtleScpCiAgICBhcCgnc2V0ICJLRklMRT0lVEVNUCVcXGxvY2FsX3NlYXJj
>> "!B64TMP!" echo aF9rZXkudG1wIicpCiAgICBhcCgncG93ZXJzaGVsbCAtTm9Qcm9maWxlIC1Db21tYW5kICIkcm5n
>> "!B64TMP!" echo PVtTZWN1cml0eS5DcnlwdG9ncmFwaHkuUmFuZG9tTnVtYmVyR2VuZXJhdG9yXTo6Q3JlYXRlKCk7
>> "!B64TMP!" echo ICRyPU5ldy1PYmplY3QgYnl0ZVtdIDMyOyAkcm5nLkdldEJ5dGVzKCRyKTsgLWpvaW4gKCRyIHwg
>> "!B64TMP!" echo Rm9yRWFjaC1PYmplY3QgeyAkXy5Ub1N0cmluZyhcJ3gyXCcpIH0pIiA+ICIlS0ZJTEUlIicpCiAg
>> "!B64TMP!" echo ICBhcCgnc2V0IC9wICIlfjE9IiA8ICIlS0ZJTEUlIicpCiAgICBhcCgnZGVsICIlS0ZJTEUlIiA+
>> "!B64TMP!" echo bnVsIDI+JjEnKQogICAgYXAoJ2V4aXQgL2IgMCcpCiAgICBhcCgnJykKICAgIGFwKCc6ZGVjb2Rl
>> "!B64TMP!" echo X2I2NCcpCiAgICBhcCgnUkVNICAlMSA9IHBhdGggdG8gYSAuYjY0IHRleHQgZmlsZSwgJTIgPSBv
>> "!B64TMP!" echo dXRwdXQgYmluYXJ5IHBhdGggKG1heSBub3QgZXhpc3QgeWV0KScpCiAgICBhcCgnUkVNICBQYXNz
>> "!B64TMP!" echo IHBhdGhzIHZpYSBQUyB2YXJpYWJsZXMgdG8gc3Vydml2ZSBzcGFjZXMgLyBxdW90ZXMgaW4gVEFS
>> "!B64TMP!" echo R0VULicpCiAgICBhcCgncG93ZXJzaGVsbCAtTm9Qcm9maWxlIC1Db21tYW5kICIkaW49JGVudjpM
>> "!B64TMP!" echo U19CNjRfSU47ICRvdXQ9JGVudjpMU19CNjRfT1VUOyBbSU8uRmlsZV06OldyaXRlQWxsQnl0ZXMo
>> "!B64TMP!" echo JG91dCwgW0NvbnZlcnRdOjpGcm9tQmFzZTY0U3RyaW5nKCgoR2V0LUNvbnRlbnQgLVJhdyAkaW4p
>> "!B64TMP!" echo IC1yZXBsYWNlIFwnXFxzXCcsXCdcJykpKSInKQogICAgYXAoJ2V4aXQgL2IgMCcpCgogICAgcmV0
>> "!B64TMP!" echo dXJuICJcclxuIi5qb2luKG91dCkgKyAiXHJcbiIKCgojID09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMg
>> "!B64TMP!" echo IExpbnV4IC8gbWFjT1MgaW5zdGFsbGVyICguc2gpCiMgPT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KCmRl
>> "!B64TMP!" echo ZiBnZW5fc2goKToKICAgIG91dCA9IFtdCiAgICBhcCA9IG91dC5hcHBlbmQKCiAgICBhcCgnIyEv
>> "!B64TMP!" echo dXNyL2Jpbi9lbnYgYmFzaCcpCiAgICBhcCgnIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBh
>> "!B64TMP!" echo cCgnIyAgTG9jYWwgU2VhcmNoIEluc3RhbGxlciAgKEZpcmVjcmF3bCArIFNlYXJYTkcgKyBsb2Nh
>> "!B64TMP!" echo bC13ZWItc2VhcmNoIHNraWxsKScpCiAgICBhcCgnIyAgICAgICAgICAgICAgICAgICAgICAgIC0g
>> "!B64TMP!" echo IExpbnV4ICYgbWFjT1MnKQogICAgYXAoJyMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAo
>> "!B64TMP!" echo JyMgIFNlbGYtY29udGFpbmVkOiBldmVyeSBmaWxlIHRoZSBpbnN0YWxsZXIgbmVlZHMgaXMgZW1i
>> "!B64TMP!" echo ZWRkZWQgYmVsb3cgYXMgYScpCiAgICBhcCgnIyAgcXVvdGVkIGhlcmVkb2MuIElmIGEgc291cmNl
>> "!B64TMP!" echo IGZpbGUgaXMgbWlzc2luZyBmcm9tIHRoaXMgc2NyaXB0XCdzIGZvbGRlcicpCiAgICBhcCgnIyAg
>> "!B64TMP!" echo KGUuZy4geW91IG9ubHkgZG93bmxvYWRlZCB0aGlzIG9uZSAuc2gpLCB0aGUgZW1iZWRkZWQgY29w
>> "!B64TMP!" echo eSBpcyB1c2VkLicpCiAgICBhcCgnIyAgQWZ0ZXIgaW5zdGFsbGluZyB0aGUgc3RhY2sgaXQgYWxz
>> "!B64TMP!" echo byBjb3BpZXMgdGhlIGJ1bmRsZWQgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCcpCiAgICBhcCgnIyAg
>> "!B64TMP!" echo c2tpbGwgaW50byB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2guJykKICAgIGFwKCcj
>> "!B64TMP!" echo ICBUaGUgaW5zdGFsbGVyIGFza3MgYSB5L04gIkFkZCBhIEZpcmVjcmF3bCBhY2NvdW50PyIgcXVl
>> "!B64TMP!" echo c3Rpb24gKGRlZmF1bHQgTik6JykKICAgIGFwKCcjICB3aXRob3V0IGFuIGFjY291bnQgb25seSB0
>> "!B64TMP!" echo aGUgZnJlZSBsb2NhbCBza2lsbCB0b29scyBhcmUgaW5zdGFsbGVkICh0aGUnKQogICAgYXAoJyMg
>> "!B64TMP!" echo IDE5IGFjY291bnQtZ2F0ZWQgc2NyaXB0cyBhcmUgc2tpcHBlZCBhbmQgYSBjb3JlLW9ubHkgU0tJ
>> "!B64TMP!" echo TEwubWQgaXMgdXNlZCk7JykKICAgIGFwKCcjICB3aXRoIG9uZSB0aGUgY3JlZGVudGlhbHMgYXJl
>> "!B64TMP!" echo IHdyaXR0ZW4gdG8gLmVudiBhbmQgYWxsIDI0IHRvb2xzIGluc3RhbGwuJykKICAgIGFwKCcjICBJ
>> "!B64TMP!" echo ZiB0aGUgRG9ja2VyIGVuZ2luZSBpcyBub3QgcnVubmluZywgdGhlIGluc3RhbGxlciB0cmllcyB0
>> "!B64TMP!" echo byBzdGFydCBpdCcpCiAgICBhcCgnIyAgYXV0b21hdGljYWxseSAoRG9ja2VyIERlc2t0b3Agb24g
>> "!B64TMP!" echo bWFjT1MsIHN5c3RlbWN0bC9zZXJ2aWNlIG9uIExpbnV4KScpCiAgICBhcCgnIyAgYW5kIHdhaXRz
>> "!B64TMP!" echo IGZvciBpdCBiZWZvcmUgcHVsbGluZyBpbWFnZXMuJykKICAgIGFwKCcjID09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09JykKICAgIGFwKCcnKQogICAgYXAoJ3NldCAtdScpCiAgICBhcCgnJykKICAgIGFwKCdC
>> "!B64TMP!" echo T0xEPSJcXDAzM1sxbSI7IERJTT0iXFwwMzNbMm0iOyBHUkVFTj0iXFwwMzNbMzJtIjsgWUVMTE9X
>> "!B64TMP!" echo PSJcXDAzM1szM20iOyBSRUQ9IlxcMDMzWzMxbSI7IENZQU49IlxcMDMzWzM2bSI7IFJFU0VUPSJc
>> "!B64TMP!" echo XDAzM1swbSInKQogICAgYXAoJ3NheSgpICB7IHByaW50ZiAiJWJcXG4iICIkMSI7IH0nKQogICAg
>> "!B64TMP!" echo YXAoJ2VycigpICB7IHByaW50ZiAiJWJbRVJST1JdJWIgJXNcXG4iICIkUkVEIiAiJFJFU0VUIiAi
>> "!B64TMP!" echo JDEiID4mMjsgfScpCiAgICBhcCgnb2soKSAgIHsgcHJpbnRmICIlYltPS10lYiAlc1xcbiIgIiRH
>> "!B64TMP!" echo UkVFTiIgIiRSRVNFVCIgIiQxIjsgfScpCiAgICBhcCgnaGRyKCkgIHsgcHJpbnRmICJcXG4lYi0t
>> "!B64TMP!" echo LSAlcyAtLS0lYlxcbiIgIiRDWUFOIiAiJDEiICIkUkVTRVQiOyB9JykKICAgIGFwKCdsb3dlcigp
>> "!B64TMP!" echo IHsgcHJpbnRmIFwnJXNcJyAiJDEiIHwgdHIgXCdbOnVwcGVyOl1cJyBcJ1s6bG93ZXI6XVwnOyB9
>> "!B64TMP!" echo ICAjIGJhc2gtMy4yIChtYWNPUykgc2FmZScpCiAgICBhcCgnJykKICAgIGFwKCdjYXQgPDxcJ0JB
>> "!B64TMP!" echo Tk5FUlwnJykKICAgIGFwKCc9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJyAgTG9jYWwgU2VhcmNoIEluc3RhbGxlciAg
>> "!B64TMP!" echo KEZpcmVjcmF3bCArIFNlYXJYTkcgKyBsb2NhbC13ZWItc2VhcmNoKScpCiAgICBhcCgnICBBIGxv
>> "!B64TMP!" echo Y2FsIHdlYi1icm93c2luZyBzeXN0ZW0gZm9yIEFJIG1vZGVscy4nKQogICAgYXAoJz09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAg
>> "!B64TMP!" echo ICBhcCgnQkFOTkVSJykKICAgIGFwKCcnKQogICAgIyBEb2NrZXIgY2hlY2sKICAgIGFwKCdpZiAh
>> "!B64TMP!" echo IGNvbW1hbmQgLXYgZG9ja2VyID4vZGV2L251bGwgMj4mMTsgdGhlbicpCiAgICBhcCgnICBlcnIg
>> "!B64TMP!" echo IkRvY2tlciB3YXMgbm90IGZvdW5kIG9uIHlvdXIgUEFUSC4iJykKICAgIGFwKCcgIHNheSAiIicp
>> "!B64TMP!" echo CiAgICBhcCgnICBzYXkgIkluc3RhbGwgRG9ja2VyIEVuZ2luZSAoTGludXgpIG9yIERvY2tlciBE
>> "!B64TMP!" echo ZXNrdG9wIChtYWNPUyk6IicpCiAgICBhcCgnICBzYXkgIiAgTGludXg6ICAgaHR0cHM6Ly9kb2Nz
>> "!B64TMP!" echo LmRvY2tlci5jb20vZW5naW5lL2luc3RhbGwvIicpCiAgICBhcCgnICBzYXkgIiAgbWFjT1M6ICAg
>> "!B64TMP!" echo aHR0cHM6Ly93d3cuZG9ja2VyLmNvbS9wcm9kdWN0cy9kb2NrZXItZGVza3RvcC8iJykKICAgIGFw
>> "!B64TMP!" echo KCcgIHNheSAiVGhlbiByZS1ydW4gdGhpcyBpbnN0YWxsZXIuIicpCiAgICBhcCgnICBleGl0IDEn
>> "!B64TMP!" echo KQogICAgYXAoJ2ZpJykKICAgICMgRG9ja2VyIGVuZ2luZSBjaGVjayAtIHRyeSB0byBTVEFSVCBp
>> "!B64TMP!" echo dCBhdXRvbWF0aWNhbGx5IHdoZW4gaXQgaXMgZG93bi4KICAgIGFwKCcjIEhvdyBsb25nIHRvIHdh
>> "!B64TMP!" echo aXQgZm9yIGEganVzdC1sYXVuY2hlZCBEb2NrZXIgZW5naW5lIChzZWNvbmRzKS4nKQogICAgYXAo
>> "!B64TMP!" echo J0RPQ0tFUl9XQUlUX1RJTUVPVVQ9IiR7TE9DQUxfU0VBUkNIX0RPQ0tFUl9USU1FT1VUOi0zMDB9
>> "!B64TMP!" echo IicpCiAgICBhcCgnRU5HSU5FX0xBVU5DSEVEPTAnKQogICAgYXAoJ2lmICEgZG9ja2VyIGluZm8g
>> "!B64TMP!" echo Pi9kZXYvbnVsbCAyPiYxOyB0aGVuJykKICAgIGFwKCcgIHNheSAiICAke1lFTExPV31bIV0ke1JF
>> "!B64TMP!" echo U0VUfSBUaGUgRG9ja2VyIGVuZ2luZSBpcyBub3QgcnVubmluZyAtIHRyeWluZyB0byBzdGFydCBp
>> "!B64TMP!" echo dC4uLiInKQogICAgYXAoJyAgRU5HSU5FX1NUQVJURUQ9MCcpCiAgICBhcCgnICBpZiBbICIkKHVu
>> "!B64TMP!" echo YW1lKSIgPSAiRGFyd2luIiBdOyB0aGVuJykKICAgIGFwKCcgICAgIyBtYWNPUzogbGF1bmNoIERv
>> "!B64TMP!" echo Y2tlciBEZXNrdG9wIGlmIGl0IGlzIGluc3RhbGxlZCcpCiAgICBhcCgnICAgIGlmIGNvbW1hbmQg
>> "!B64TMP!" echo LXYgb3BlbiA+L2Rldi9udWxsIDI+JjEgXFwnKQogICAgYXAoJyAgICAgICAmJiB7IFsgLWQgIi9B
>> "!B64TMP!" echo cHBsaWNhdGlvbnMvRG9ja2VyLmFwcCIgXSB8fCBbIC1kICIkSE9NRS9BcHBsaWNhdGlvbnMvRG9j
>> "!B64TMP!" echo a2VyLmFwcCIgXTsgfTsgdGhlbicpCiAgICBhcCgnICAgICAgb3BlbiAtYSBEb2NrZXIgPi9kZXYv
>> "!B64TMP!" echo bnVsbCAyPiYxICYmIEVOR0lORV9TVEFSVEVEPTEnKQogICAgYXAoJyAgICBmaScpCiAgICBhcCgn
>> "!B64TMP!" echo ICBlbHNlJykKICAgIGFwKCcgICAgIyBMaW51eDogc3lzdGVtZCB1bml0cyAoRG9ja2VyIERlc2t0
>> "!B64TMP!" echo b3AgdXNlcyBkb2NrZXItZGVza3RvcCwgdGhlJykKICAgIGFwKCcgICAgIyBjbGFzc2ljIGVuZ2lu
>> "!B64TMP!" echo ZSB1c2VzIGRvY2tlciksIHRoZW4gc2VydmljZSgxKS4gTm9uLWludGVyYWN0aXZlJykKICAgIGFw
>> "!B64TMP!" echo KCcgICAgIyBzdWRvIG9ubHkgLSBhbiBpbnN0YWxsZXIgbmV2ZXIgcHJvbXB0cyBmb3IgYSBwYXNz
>> "!B64TMP!" echo d29yZC4nKQogICAgYXAoJyAgICBpZiBjb21tYW5kIC12IHN5c3RlbWN0bCA+L2Rldi9udWxsIDI+
>> "!B64TMP!" echo JjE7IHRoZW4nKQogICAgYXAoJyAgICAgIGZvciB1bml0IGluIGRvY2tlci1kZXNrdG9wIGRvY2tl
>> "!B64TMP!" echo cjsgZG8nKQogICAgYXAoJyAgICAgICAgaWYgc3lzdGVtY3RsIHN0YXJ0ICIkdW5pdCIgPi9kZXYv
>> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuIEVOR0lORV9TVEFSVEVEPTE7IGJyZWFrOyBmaScpCiAgICBhcCgnICAg
>> "!B64TMP!" echo ICAgICBpZiBjb21tYW5kIC12IHN1ZG8gPi9kZXYvbnVsbCAyPiYxIFxcJykKICAgIGFwKCcgICAg
>> "!B64TMP!" echo ICAgICAgICYmIHN1ZG8gLW4gc3lzdGVtY3RsIHN0YXJ0ICIkdW5pdCIgPi9kZXYvbnVsbCAyPiYx
>> "!B64TMP!" echo OyB0aGVuJykKICAgIGFwKCcgICAgICAgICAgRU5HSU5FX1NUQVJURUQ9MTsgYnJlYWsnKQogICAg
>> "!B64TMP!" echo YXAoJyAgICAgICAgZmknKQogICAgYXAoJyAgICAgIGRvbmUnKQogICAgYXAoJyAgICBmaScpCiAg
>> "!B64TMP!" echo ICBhcCgnICAgIGlmIFsgIiRFTkdJTkVfU1RBUlRFRCIgLW5lIDEgXSAmJiBjb21tYW5kIC12IHNl
>> "!B64TMP!" echo cnZpY2UgPi9kZXYvbnVsbCAyPiYxOyB0aGVuJykKICAgIGFwKCcgICAgICBpZiBzZXJ2aWNlIGRv
>> "!B64TMP!" echo Y2tlciBzdGFydCA+L2Rldi9udWxsIDI+JjE7IHRoZW4gRU5HSU5FX1NUQVJURUQ9MScpCiAgICBh
>> "!B64TMP!" echo cCgnICAgICAgZWxpZiBjb21tYW5kIC12IHN1ZG8gPi9kZXYvbnVsbCAyPiYxIFxcJykKICAgIGFw
>> "!B64TMP!" echo KCcgICAgICAgICAmJiBzdWRvIC1uIHNlcnZpY2UgZG9ja2VyIHN0YXJ0ID4vZGV2L251bGwgMj4m
>> "!B64TMP!" echo MTsgdGhlbicpCiAgICBhcCgnICAgICAgICBFTkdJTkVfU1RBUlRFRD0xJykKICAgIGFwKCcgICAg
>> "!B64TMP!" echo ICBmaScpCiAgICBhcCgnICAgIGZpJykKICAgIGFwKCcgIGZpJykKICAgIGFwKCcgIGlmIFsgIiRF
>> "!B64TMP!" echo TkdJTkVfU1RBUlRFRCIgLW5lIDEgXTsgdGhlbicpCiAgICBhcCgnICAgIGVyciAiQ291bGQgbm90
>> "!B64TMP!" echo IHN0YXJ0IHRoZSBEb2NrZXIgZW5naW5lIGF1dG9tYXRpY2FsbHkuIicpCiAgICBhcCgnICAgIHNh
>> "!B64TMP!" echo eSAiIicpCiAgICBhcCgnICAgIHNheSAiU3RhcnQgaXQgbWFudWFsbHksIHRoZW4gcmUtcnVuIHRo
>> "!B64TMP!" echo aXMgaW5zdGFsbGVyOiInKQogICAgYXAoJyAgICBzYXkgIiAgTGludXg6ICBzdWRvIHN5c3RlbWN0
>> "!B64TMP!" echo bCBzdGFydCBkb2NrZXIgICAgKG9yIGxhdW5jaCBEb2NrZXIgRGVza3RvcCkiJykKICAgIGFwKCcg
>> "!B64TMP!" echo ICAgc2F5ICIgICAgICAgICAgcGVybWlzc2lvbiBkZW5pZWQgZnJvbSBkb2NrZXI/IGFkZCB5b3Vy
>> "!B64TMP!" echo c2VsZiB0byB0aGUgZG9ja2VyIicpCiAgICBhcCgnICAgIHNheSAiICAgICAgICAgIGdyb3VwOiAg
>> "!B64TMP!" echo c3VkbyB1c2VybW9kIC1hRyBkb2NrZXIgJFVTRVIgIChsb2cgb3V0IGFuZCBiYWNrIGluKSInKQog
>> "!B64TMP!" echo ICAgYXAoJyAgICBzYXkgIiAgbWFjT1M6ICBvcGVuIC1hIERvY2tlciInKQogICAgYXAoJyAgICBl
>> "!B64TMP!" echo eGl0IDEnKQogICAgYXAoJyAgZmknKQogICAgYXAoJyAgRU5HSU5FX0xBVU5DSEVEPTEnKQogICAg
>> "!B64TMP!" echo YXAoJyAgc2F5ICIgIExhdW5jaGVkIERvY2tlciBpbiB0aGUgYmFja2dyb3VuZC4gQW5zd2VyIHRo
>> "!B64TMP!" echo ZSBuZXh0IHF1ZXN0aW9ucyB3aGlsZSInKQogICAgYXAoJyAgc2F5ICIgIGl0IGJvb3RzIC0gdGhl
>> "!B64TMP!" echo IGluc3RhbGxlciB3YWl0cyBmb3IgdGhlIGVuZ2luZSBiZWZvcmUgcHVsbGluZyBpbWFnZXMuIicp
>> "!B64TMP!" echo CiAgICBhcCgnZmknKQogICAgYXAoJ2lmIGRvY2tlciBjb21wb3NlIHZlcnNpb24gPi9kZXYvbnVs
>> "!B64TMP!" echo bCAyPiYxOyB0aGVuIERDPSJkb2NrZXIgY29tcG9zZSInKQogICAgYXAoJ2VsaWYgY29tbWFuZCAt
>> "!B64TMP!" echo diBkb2NrZXItY29tcG9zZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRvY2tlci1jb21wb3Nl
>> "!B64TMP!" echo IicpCiAgICBhcCgnZWxzZSBlcnIgIkRvY2tlciBDb21wb3NlIHdhcyBub3QgZm91bmQuIEluc3Rh
>> "!B64TMP!" echo bGwgdGhlIFwnZG9ja2VyIGNvbXBvc2VcJyBwbHVnaW4gKHYyKS4iOyBleGl0IDE7IGZpJykKICAg
>> "!B64TMP!" echo IGFwKCdvayAiRG9ja2VyIGFuZCBEb2NrZXIgQ29tcG9zZSBhcmUgYXZhaWxhYmxlICgkREMpLiIn
>> "!B64TMP!" echo KQogICAgYXAoJycpCiAgICAjIFNvdXJjZSBmb2xkZXIKICAgIGFwKCdTUkM9IiQoY2QgIiQoZGly
>> "!B64TMP!" echo bmFtZSAiJDAiKSIgJiYgcHdkKSInKQogICAgYXAoJycpCiAgICAjIFByb21wdHMKICAgIGFwKCdE
>> "!B64TMP!" echo RUZBVUxUX1RBUkdFVD0iJEhPTUUvbG9jYWwtc2VhcmNoIicpCiAgICBhcCgnaGRyICJTdGVwIDEg
>> "!B64TMP!" echo b2YgNTogSW5zdGFsbCBsb2NhdGlvbiInKQogICAgYXAoJ3NheSAiICBEZWZhdWx0OiAkREVGQVVM
>> "!B64TMP!" echo VF9UQVJHRVQiJykKICAgIGFwKCdwcmludGYgIiAgVGFyZ2V0IGZvbGRlciBbcHJlc3MgRW50ZXIg
>> "!B64TMP!" echo Zm9yIGRlZmF1bHRdOiAiJykKICAgIGFwKCdyZWFkIC1yIFRBUkdFVCcpCiAgICBhcCgnWyAteiAi
>> "!B64TMP!" echo JFRBUkdFVCIgXSAmJiBUQVJHRVQ9IiRERUZBVUxUX1RBUkdFVCInKQogICAgYXAoJ2lmIFsgIiR7
>> "!B64TMP!" echo VEFSR0VUI1xcfn0iICE9ICIkVEFSR0VUIiBdOyB0aGVuIFRBUkdFVD0iJEhPTUUke1RBUkdFVCNc
>> "!B64TMP!" echo XH59IjsgZmkgICMgUE9TSVggdGlsZGUgZXhwYW5zaW9uJykKICAgIGFwKCdta2RpciAtcCAiJFRB
>> "!B64TMP!" echo UkdFVCInKQogICAgYXAoJ1RBUkdFVD0iJChjZCAiJFRBUkdFVCIgJiYgcHdkKSInKQogICAgYXAo
>> "!B64TMP!" echo J3NheSAiICBVc2luZzogJFRBUkdFVCInKQogICAgYXAoJycpCiAgICBhcCgndmFsaWRhdGVfcG9y
>> "!B64TMP!" echo dCgpIHsnKQogICAgYXAoJyAgbG9jYWwgcD0iJDEiJykKICAgIGFwKCcgIFtbICIkcCIgPX4gXlsw
>> "!B64TMP!" echo LTldKyQgXV0gfHwgcmV0dXJuIDEnKQogICAgYXAoJyAgWyAiJHAiIC1nZSAxIF0gMj4vZGV2L251
>> "!B64TMP!" echo bGwgfHwgcmV0dXJuIDEnKQogICAgYXAoJyAgWyAiJHAiIC1sZSA2NTUzNSBdIDI+L2Rldi9udWxs
>> "!B64TMP!" echo IHx8IHJldHVybiAxJykKICAgIGFwKCcgIHJldHVybiAwJykKICAgIGFwKCd9JykKICAgIGFwKCcn
>> "!B64TMP!" echo KQogICAgYXAoJ2hkciAiU3RlcCAyIG9mIDU6IFNlYXJYTkcgcG9ydCAoZGVmYXVsdCA5OTkwKSIn
>> "!B64TMP!" echo KQogICAgYXAoJ3doaWxlIHRydWU7IGRvJykKICAgIGFwKCcgIHByaW50ZiAiICBQb3J0IGZvciBT
>> "!B64TMP!" echo ZWFyWE5HIFtwcmVzcyBFbnRlciBmb3IgOTk5MF06ICInKQogICAgYXAoJyAgcmVhZCAtciBTRUFS
>> "!B64TMP!" echo WE5HX1BPUlQnKQogICAgYXAoJyAgWyAteiAiJFNFQVJYTkdfUE9SVCIgXSAmJiBTRUFSWE5HX1BP
>> "!B64TMP!" echo UlQ9OTk5MCcpCiAgICBhcCgnICBpZiB2YWxpZGF0ZV9wb3J0ICIkU0VBUlhOR19QT1JUIjsgdGhl
>> "!B64TMP!" echo biBicmVhazsgZmknKQogICAgYXAoJyAgc2F5ICIgICR7WUVMTE9XfVshXSR7UkVTRVR9IFwnJFNF
>> "!B64TMP!" echo QVJYTkdfUE9SVFwnIGlzIG5vdCBhIHZhbGlkIHBvcnQgKDEtNjU1MzUpLiInKQogICAgYXAoJ2Rv
>> "!B64TMP!" echo bmUnKQogICAgYXAoJycpCiAgICBhcCgnaGRyICJTdGVwIDMgb2YgNTogRmlyZWNyYXdsIHBvcnQg
>> "!B64TMP!" echo KGRlZmF1bHQgOTk5MSkiJykKICAgIGFwKCd3aGlsZSB0cnVlOyBkbycpCiAgICBhcCgnICBwcmlu
>> "!B64TMP!" echo dGYgIiAgUG9ydCBmb3IgRmlyZWNyYXdsIFtwcmVzcyBFbnRlciBmb3IgOTk5MV06ICInKQogICAg
>> "!B64TMP!" echo YXAoJyAgcmVhZCAtciBGSVJFQ1JBV0xfUE9SVCcpCiAgICBhcCgnICBbIC16ICIkRklSRUNSQVdM
>> "!B64TMP!" echo X1BPUlQiIF0gJiYgRklSRUNSQVdMX1BPUlQ9OTk5MScpCiAgICBhcCgnICBpZiAhIHZhbGlkYXRl
>> "!B64TMP!" echo X3BvcnQgIiRGSVJFQ1JBV0xfUE9SVCI7IHRoZW4nKQogICAgYXAoJyAgICBzYXkgIiAgJHtZRUxM
>> "!B64TMP!" echo T1d9WyFdJHtSRVNFVH0gXCckRklSRUNSQVdMX1BPUlRcJyBpcyBub3QgYSB2YWxpZCBwb3J0ICgx
>> "!B64TMP!" echo LTY1NTM1KS4iJykKICAgIGFwKCcgICAgY29udGludWUnKQogICAgYXAoJyAgZmknKQogICAgYXAo
>> "!B64TMP!" echo JyAgaWYgWyAiJEZJUkVDUkFXTF9QT1JUIiA9ICIkU0VBUlhOR19QT1JUIiBdOyB0aGVuJykKICAg
>> "!B64TMP!" echo IGFwKCcgICAgc2F5ICIgICR7WUVMTE9XfVshXSR7UkVTRVR9IEZpcmVjcmF3bCBwb3J0IG11c3Qg
>> "!B64TMP!" echo ZGlmZmVyIGZyb20gU2VhclhORyBwb3J0LiInKQogICAgYXAoJyAgICBjb250aW51ZScpCiAgICBh
>> "!B64TMP!" echo cCgnICBmaScpCiAgICBhcCgnICBicmVhaycpCiAgICBhcCgnZG9uZScpCiAgICBhcCgnJykKICAg
>> "!B64TMP!" echo IGFwKCdoZHIgIlN0ZXAgNCBvZiA1OiBMb2NhbCBMTE0gKG9wdGlvbmFsKSInKQogICAgYXAoJ3Nh
>> "!B64TMP!" echo eSAiICBMZXRzIEZpcmVjcmF3bCBkbyBBSSBleHRyYWN0aW9uICgvdjEvZXh0cmFjdCkgYW5kIHN1
>> "!B64TMP!" echo bW1hcmllcy4iJykKICAgIGFwKCdzYXkgIiAgUmVjb21tZW5kZWQ6IExNIFN0dWRpbyAtPiBodHRw
>> "!B64TMP!" echo Oi8vbG9jYWxob3N0OjEyMzQvdjEiJykKICAgIGFwKCdwcmludGYgIiAgQ29ubmVjdCBhIGxvY2Fs
>> "!B64TMP!" echo IExMTSBub3c/IFt5L05dOiAiJykKICAgIGFwKCdyZWFkIC1yIFVTRV9MTE0nKQogICAgYXAoJ09Q
>> "!B64TMP!" echo RU5BSV9CQVNFX1VSTD0iIjsgT1BFTkFJX0FQSV9LRVk9IiI7IE1PREVMX05BTUU9IiInKQogICAg
>> "!B64TMP!" echo YXAoJ2lmIFsgIiQobG93ZXIgIiRVU0VfTExNIikiID0gInkiIF07IHRoZW4nKQogICAgYXAoJyAg
>> "!B64TMP!" echo cHJpbnRmICIgICAgTE0gU3R1ZGlvIHNlcnZlciBVUkwgKGFzIHNob3duIGluIExNIFN0dWRpbykg
>> "!B64TMP!" echo W3ByZXNzIEVudGVyIGZvciBodHRwOi8vbG9jYWxob3N0OjEyMzQvdjFdOiAiJykKICAgIGFwKCcg
>> "!B64TMP!" echo IHJlYWQgLXIgTExNX1VSTCcpCiAgICBhcCgnICBbIC16ICIkTExNX1VSTCIgXSAmJiBMTE1fVVJM
>> "!B64TMP!" echo PSJodHRwOi8vbG9jYWxob3N0OjEyMzQvdjEiJykKICAgIGFwKCcgIHByaW50ZiAiICAgIE1vZGVs
>> "!B64TMP!" echo IG5hbWUgKGlkIGxvYWRlZCBpbiBMTSBTdHVkaW8pIFtwcmVzcyBFbnRlciB0byBza2lwXTogIicp
>> "!B64TMP!" echo CiAgICBhcCgnICByZWFkIC1yIExMTV9NT0RFTCcpCiAgICBhcCgnICBPUEVOQUlfQkFTRV9VUkw9
>> "!B64TMP!" echo IiR7TExNX1VSTC9odHRwOlxcL1xcL2xvY2FsaG9zdC9odHRwOlxcL1xcL2hvc3QuZG9ja2VyLmlu
>> "!B64TMP!" echo dGVybmFsfSInKQogICAgYXAoJyAgT1BFTkFJX0JBU0VfVVJMPSIke09QRU5BSV9CQVNFX1VSTC9o
>> "!B64TMP!" echo dHRwOlxcL1xcLzEyNy4wLjAuMS9odHRwOlxcL1xcL2hvc3QuZG9ja2VyLmludGVybmFsfSInKQog
>> "!B64TMP!" echo ICAgYXAoJyAgT1BFTkFJX0FQSV9LRVk9ImxtLXN0dWRpbyInKQogICAgYXAoJyAgWyAtbiAiJExM
>> "!B64TMP!" echo TV9NT0RFTCIgXSAmJiBNT0RFTF9OQU1FPSIkTExNX01PREVMIicpCiAgICBhcCgnICBzYXkgIiAg
>> "!B64TMP!" echo ICAoQ29udGFpbmVyIHdpbGwgcmVhY2ggaXQgYXQ6ICRPUEVOQUlfQkFTRV9VUkwpIicpCiAgICBh
>> "!B64TMP!" echo cCgnICBzYXkgIiAgICAoTWFrZSBzdXJlIExNIFN0dWRpbyBoYXMgXCdTZXJ2ZSBvbiBsb2NhbCBu
>> "!B64TMP!" echo ZXR3b3JrXCcgZW5hYmxlZC4pIicpCiAgICBhcCgnZmknKQogICAgYXAoJycpCiAgICAjIFN0ZXAg
>> "!B64TMP!" echo NTogb3B0aW9uYWwgRmlyZWNyYXdsIGFjY291bnQgKHVubG9ja3MgdGhlIGFjY291bnQtZ2F0ZWQg
>> "!B64TMP!" echo dG9vbHMpCiAgICBhcCgnaGRyICJTdGVwIDUgb2YgNTogRmlyZWNyYXdsIGFjY291bnQgKG9wdGlv
>> "!B64TMP!" echo bmFsKSInKQogICAgYXAoJ3NheSAiICBUaGUgZXh0cmEgdG9vbHMgKHJlc2VhcmNoIGFnZW50LCBs
>> "!B64TMP!" echo aXZlLXBhZ2UgaW50ZXJhY3QsIGZpbGUgcGFyc2UsIicpCiAgICBhcCgnc2F5ICIgIG1vbml0b3Jz
>> "!B64TMP!" echo LCBwYXBlciByZXNlYXJjaCwgR2l0SHViL2RldmVsb3BlciBzZWFyY2gpIG9ubHkgd29yayInKQog
>> "!B64TMP!" echo ICAgYXAoJ3NheSAiICB3aXRoIGEgRmlyZWNyYXdsIGFjY291bnQgQVBJIGtleSAocGFpZCBjbG91
>> "!B64TMP!" echo ZCBzZXJ2aWNlKToiJykKICAgIGFwKCdzYXkgIiAgICBodHRwczovL3d3dy5maXJlY3Jhd2wuZGV2
>> "!B64TMP!" echo IicpCiAgICBhcCgnc2F5ICIgIEFuc3dlciBOIHRvIGluc3RhbGwgb25seSB0aGUgZnJlZSBsb2Nh
>> "!B64TMP!" echo bCB0b29scyAoZGVmYXVsdCkuIicpCiAgICBhcCgncHJpbnRmICIgIEFkZCBhIEZpcmVjcmF3bCBh
>> "!B64TMP!" echo Y2NvdW50IG5vdz8gW3kvTl06ICInKQogICAgYXAoJ1VTRV9GQz0iIicpCiAgICBhcCgncmVhZCAt
>> "!B64TMP!" echo ciBVU0VfRkMgfHwgVVNFX0ZDPSIiJykKICAgIGFwKCdGQ19BUElfS0VZPSIiOyBGQ19BUElfVVJM
>> "!B64TMP!" echo PSIiJykKICAgIGFwKCdpZiBbICIkKGxvd2VyICIkVVNFX0ZDIikiID0gInkiIF07IHRoZW4nKQog
>> "!B64TMP!" echo ICAgYXAoJyAgRkNfVFJJRVM9MCcpCiAgICBhcCgnICB3aGlsZSB0cnVlOyBkbycpCiAgICBhcCgn
>> "!B64TMP!" echo ICAgIHByaW50ZiAiICAgIEZpcmVjcmF3bCBBUEkga2V5IChmcm9tIGh0dHBzOi8vd3d3LmZpcmVj
>> "!B64TMP!" echo cmF3bC5kZXYpOiAiJykKICAgIGFwKCcgICAgaWYgISByZWFkIC1yIEZDX0FQSV9LRVk7IHRoZW4g
>> "!B64TMP!" echo RkNfQVBJX0tFWT0iIjsgYnJlYWs7IGZpJykKICAgIGFwKCcgICAgWyAtbiAiJEZDX0FQSV9LRVki
>> "!B64TMP!" echo IF0gJiYgYnJlYWsnKQogICAgYXAoJyAgICBGQ19UUklFUz0kKChGQ19UUklFUyArIDEpKScpCiAg
>> "!B64TMP!" echo ICBhcCgnICAgIGlmIFsgIiRGQ19UUklFUyIgLWdlIDMgXTsgdGhlbicpCiAgICBhcCgnICAgICAg
>> "!B64TMP!" echo c2F5ICIgICAgJHtZRUxMT1d9WyFdJHtSRVNFVH0gbm8gQVBJIGtleSBlbnRlcmVkIC0gY29udGlu
>> "!B64TMP!" echo dWluZyBXSVRIT1VUIGEgRmlyZWNyYXdsIGFjY291bnQuIicpCiAgICBhcCgnICAgICAgRkNfQVBJ
>> "!B64TMP!" echo X0tFWT0iIicpCiAgICBhcCgnICAgICAgYnJlYWsnKQogICAgYXAoJyAgICBmaScpCiAgICBhcCgn
>> "!B64TMP!" echo ICAgIHNheSAiICAgICR7WUVMTE9XfVshXSR7UkVTRVR9IHRoZSBBUEkga2V5IGNhbm5vdCBiZSBl
>> "!B64TMP!" echo bXB0eSAtIHRyeSBhZ2Fpbi4iJykKICAgIGFwKCcgIGRvbmUnKQogICAgYXAoJyAgaWYgWyAtbiAi
>> "!B64TMP!" echo JEZDX0FQSV9LRVkiIF07IHRoZW4nKQogICAgYXAoJyAgICBwcmludGYgIiAgICBGaXJlY3Jhd2wg
>> "!B64TMP!" echo QVBJIFVSTCBbcHJlc3MgRW50ZXIgZm9yIGh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXZdOiAiJykK
>> "!B64TMP!" echo ICAgIGFwKCcgICAgcmVhZCAtciBGQ19BUElfVVJMIHx8IEZDX0FQSV9VUkw9IiInKQogICAgYXAo
>> "!B64TMP!" echo JyAgICBbIC16ICIkRkNfQVBJX1VSTCIgXSAmJiBGQ19BUElfVVJMPSJodHRwczovL2FwaS5maXJl
>> "!B64TMP!" echo Y3Jhd2wuZGV2IicpCiAgICBhcCgnICBmaScpCiAgICBhcCgnZmknKQogICAgYXAoJycpCiAgICAj
>> "!B64TMP!" echo IFN1bW1hcnkgKyBjb25maXJtCiAgICBhcCgnZWNobycpCiAgICBhcCgnc2F5ICIke0JPTER9PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo JHtSRVNFVH0iJykKICAgIGFwKCdzYXkgIiR7Qk9MRH0gIFN1bW1hcnkke1JFU0VUfSInKQogICAg
>> "!B64TMP!" echo YXAoJ3NheSAiICBGb2xkZXI6ICAgICAgICAgJFRBUkdFVCInKQogICAgYXAoJ3NheSAiICBTZWFy
>> "!B64TMP!" echo WE5HIHBvcnQ6ICAgJFNFQVJYTkdfUE9SVCInKQogICAgYXAoJ3NheSAiICBGaXJlY3Jhd2wgcG9y
>> "!B64TMP!" echo dDogJEZJUkVDUkFXTF9QT1JUIicpCiAgICBhcCgnc2F5ICIgIEFnZW50IHNraWxsOiAgICAkSE9N
>> "!B64TMP!" echo RS8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoIicpCiAgICBhcCgnaWYgWyAtbiAiJE9Q
>> "!B64TMP!" echo RU5BSV9CQVNFX1VSTCIgXTsgdGhlbicpCiAgICBhcCgnICBzYXkgIiAgTExNIGVuZHBvaW50OiAg
>> "!B64TMP!" echo ICRPUEVOQUlfQkFTRV9VUkwgICRNT0RFTF9OQU1FIicpCiAgICBhcCgnZWxzZScpCiAgICBhcCgn
>> "!B64TMP!" echo ICBzYXkgIiAgTExNIGVuZHBvaW50OiAgIChub25lIC0gZW5hYmxlIGxhdGVyIGJ5IGVkaXRpbmcg
>> "!B64TMP!" echo LmVudikiJykKICAgIGFwKCdmaScpCiAgICBhcCgnaWYgWyAtbiAiJEZDX0FQSV9LRVkiIF07IHRo
>> "!B64TMP!" echo ZW4nKQogICAgYXAoJyAgc2F5ICIgIEZpcmVjcmF3bCBhY2N0OiAkRkNfQVBJX1VSTCAgKGFjY291
>> "!B64TMP!" echo bnQgdG9vbHMgaW5zdGFsbGVkKSInKQogICAgYXAoJ2Vsc2UnKQogICAgYXAoJyAgc2F5ICIgIEZp
>> "!B64TMP!" echo cmVjcmF3bCBhY2N0OiAobm9uZSAtIGZyZWUgbG9jYWwgdG9vbHMgb25seSkiJykKICAgIGFwKCdm
>> "!B64TMP!" echo aScpCiAgICBhcCgnc2F5ICIke0JPTER9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09JHtSRVNFVH0iJykKICAgIGFwKCdwcmludGYgIlBy
>> "!B64TMP!" echo b2NlZWQgd2l0aCBpbnN0YWxsPyBbWS9uXTogIicpCiAgICBhcCgncmVhZCAtciBDT05GSVJNJykK
>> "!B64TMP!" echo ICAgIGFwKCdpZiBbICIkKGxvd2VyICIkQ09ORklSTSIpIiA9ICJuIiBdOyB0aGVuIHNheSAiSW5z
>> "!B64TMP!" echo dGFsbCBjYW5jZWxsZWQuIjsgZXhpdCAwOyBmaScpCiAgICBhcCgnJykKICAgICMgQ3JlYXRlIGZv
>> "!B64TMP!" echo bGRlcnMKICAgIGFwKCdta2RpciAtcCAiJFRBUkdFVC9jb25maWcvc2VhcnhuZyIgIiRUQVJHRVQv
>> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzIicpCiAgICBhcCgnJykKICAgICMgQmFja3VwIGV4aXN0
>> "!B64TMP!" echo aW5nIC5lbnYKICAgIGFwKCdpZiBbIC1mICIkVEFSR0VULy5lbnYiIF07IHRoZW4nKQogICAgYXAo
>> "!B64TMP!" echo JyAgTERUPSIkKGRhdGUgKyVZJW0lZCVIJU0lUykiJykKICAgIGFwKCcgIGNwICIkVEFSR0VULy5l
>> "!B64TMP!" echo bnYiICIkVEFSR0VULy5lbnYuYmFrLiRMRFQiJykKICAgIGFwKCcgIHNheSAiICBCYWNrZWQgdXAg
>> "!B64TMP!" echo ZXhpc3RpbmcgLmVudiB0byAuZW52LmJhay4kTERUIicpCiAgICBhcCgnZmknKQogICAgYXAoJycp
>> "!B64TMP!" echo CiAgICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0KICAgICMgIE1hdGVyaWFsaXNlIGV2ZXJ5IHByb2plY3QgZmlsZTog
>> "!B64TMP!" echo Y29weSBmcm9tIHNvdXJjZSBpZiBwcmVzZW50LCBlbHNlCiAgICAjICB1c2UgdGhlIGVtYmVkZGVk
>> "!B64TMP!" echo IGhlcmVkb2MgZm9yIHRoYXQgZmlsZS4KICAgICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAgYXAoJ3NheSAiQ29w
>> "!B64TMP!" echo eWluZyBhbGwgcHJvamVjdCBmaWxlcy4uLiInKQoKICAgIGZvciByZWwsIHNyYyBpbiBGSUxFUzoK
>> "!B64TMP!" echo ICAgICAgICBkYXRhID0gcmVhZChzcmMpCiAgICAgICAgdGV4dCA9IGRhdGEuZGVjb2RlKCJ1dGYt
>> "!B64TMP!" echo OCIpCiAgICAgICAgdGFnID0gIkVPRl8iICsgIiIuam9pbihjIGlmIGMuaXNhbG51bSgpIGVsc2Ug
>> "!B64TMP!" echo Il8iIGZvciBjIGluIHJlbCkudXBwZXIoKQogICAgICAgIGFwKCcnKQogICAgICAgIGFwKCcjIC0t
>> "!B64TMP!" echo LSAnICsgcmVsICsgJyAtLS0nKQogICAgICAgIGFwKCdpZiBbIC1mICIkU1JDLycgKyByZWwgKyAn
>> "!B64TMP!" echo IiBdOyB0aGVuJykKICAgICAgICBhcCgnICBjcCAiJFNSQy8nICsgcmVsICsgJyIgIiRUQVJHRVQv
>> "!B64TMP!" echo JyArIHJlbCArICciJykKICAgICAgICBhcCgnZWxzZScpCiAgICAgICAgYXAoJyAgc2F5ICIgIFtl
>> "!B64TMP!" echo bWJlZGRlZF0gJyArIHJlbCArICcgIChzb3VyY2Ugbm90IGZvdW5kIG5leHQgdG8gaW5zdGFsbGVy
>> "!B64TMP!" echo OyB1c2luZyBidWlsdC1pbiBjb3B5KSInKQogICAgICAgIGFwKCcgIGNhdCA+ICIkVEFSR0VULycg
>> "!B64TMP!" echo KyByZWwgKyAnIiA8PFwnJyArIHRhZyArICdcJycpCiAgICAgICAgIyBOb3JtYWxpc2UgbGluZSBl
>> "!B64TMP!" echo bmRpbmdzIHRvIExGIGluIHRoZSBoZXJlZG9jIGJvZHkgc28gdGhlIHJ1bnRpbWUKICAgICAgICAj
>> "!B64TMP!" echo IENSTEYtY29udmVyc2lvbiBsb29wIHByb2R1Y2VzIGNsZWFuIENSTEYgKG5vdCBcclxyXG4pIGZv
>> "!B64TMP!" echo ciAuYmF0IGZpbGVzLgogICAgICAgICMgc3BsaXRsaW5lcygpIGF2b2lkcyBhIHNwdXJpb3VzIHRy
>> "!B64TMP!" echo YWlsaW5nIGVtcHR5IGxpbmUgdGhhdCB3b3VsZAogICAgICAgICMgb3RoZXJ3aXNlIGFkZCBhIGJs
>> "!B64TMP!" echo YW5rIGxpbmUgYXQgdGhlIGVuZCBvZiBldmVyeSBlbWJlZGRlZCBmaWxlLgogICAgICAgIHRleHRf
>> "!B64TMP!" echo bGYgPSB0ZXh0LnJlcGxhY2UoIlxyXG4iLCAiXG4iKS5yZXBsYWNlKCJcciIsICJcbiIpCiAgICAg
>> "!B64TMP!" echo ICAgZm9yIGxpbmUgaW4gdGV4dF9sZi5zcGxpdGxpbmVzKCk6CiAgICAgICAgICAgIGFwKGxpbmUp
>> "!B64TMP!" echo CiAgICAgICAgYXAodGFnKQogICAgICAgIGFwKCdmaScpCgogICAgIyBpbmNsdWRlIHRoZSBpbnN0
>> "!B64TMP!" echo YWxsZXJzIHRoZW1zZWx2ZXMKICAgIGFwKCdbIC1mICIkU1JDL2luc3RhbGwtbG9jYWwtc2VhcmNo
>> "!B64TMP!" echo LnNoIiBdICYmIGNwICIkU1JDL2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoIiAiJFRBUkdFVC9pbnN0
>> "!B64TMP!" echo YWxsLWxvY2FsLXNlYXJjaC5zaCInKQogICAgYXAoJ1sgLWYgIiRTUkMvaW5zdGFsbC1sb2NhbC1z
>> "!B64TMP!" echo ZWFyY2guYmF0IiBdICYmIGNwICIkU1JDL2luc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCIgIiRUQVJH
>> "!B64TMP!" echo RVQvaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IicpCiAgICBhcCgnIyBBbHdheXMgYWxzbyBkcm9w
>> "!B64TMP!" echo IHRoZSAqY3VycmVudCogaW5zdGFsbGVyICh0aGlzIHNjcmlwdCkgaW50byB0YXJnZXQsIGV2ZW4n
>> "!B64TMP!" echo KQogICAgYXAoJyMgaWYgaXQgd2FzIHJlbmFtZWQgKHRoZSBjaGVjayBhYm92ZSBsb29rcyBmb3Ig
>> "!B64TMP!" echo dGhlIGNhbm9uaWNhbCBuYW1lKS4nKQogICAgYXAoJ2NwIC1mICIkMCIgIiRUQVJHRVQvaW5zdGFs
>> "!B64TMP!" echo bC1sb2NhbC1zZWFyY2guc2giIDI+L2Rldi9udWxsIHx8IHRydWUnKQogICAgYXAoJ2NobW9kICt4
>> "!B64TMP!" echo ICIkVEFSR0VUIi8qLnNoIDI+L2Rldi9udWxsIHx8IHRydWUnKQogICAgYXAoJycpCiAgICAjIEVu
>> "!B64TMP!" echo c3VyZSBldmVyeSAuYmF0IGZpbGUgaW4gVEFSR0VUIGhhcyBDUkxGIGxpbmUgZW5kaW5ncyAoV2lu
>> "!B64TMP!" echo ZG93cyBjbWQgaXMKICAgICMgaGFwcGllciB3aXRoIENSTEY7IHRoZSBoZXJlZG9jcyBhYm92ZSB3
>> "!B64TMP!" echo cm90ZSBMRiwgd2hpY2ggd29ya3MgYnV0IGlzbid0CiAgICAjIGlkZWFsIHdoZW4gdGhlIGZvbGRl
>> "!B64TMP!" echo ciBpcyBsYXRlciBjb3BpZWQgdG8gYSBXaW5kb3dzIG1hY2hpbmUpLgogICAgIyBUaGUgc2VkIGlz
>> "!B64TMP!" echo IGlkZW1wb3RlbnQ6IHN0cmlwIGFueSB0cmFpbGluZyBDUiBmaXJzdCwgdGhlbiBhZGQgb25lIGJh
>> "!B64TMP!" echo Y2ssCiAgICAjIHNvIGZpbGVzIGNvcGllZCBmcm9tIHNvdXJjZSAoYWxyZWFkeSBDUkxGKSBhcmUg
>> "!B64TMP!" echo bm90IGRvdWJsZS1jb252ZXJ0ZWQuCiAgICBhcCgnZm9yIGYgaW4gIiRUQVJHRVQiLyouYmF0OyBk
>> "!B64TMP!" echo bycpCiAgICBhcCgnICBbIC1mICIkZiIgXSB8fCBjb250aW51ZScpCiAgICBhcCgnICBpZiBjb21t
>> "!B64TMP!" echo YW5kIC12IGF3ayA+L2Rldi9udWxsIDI+JjE7IHRoZW4nKQogICAgYXAoJyAgICBhd2sgXCd7c3Vi
>> "!B64TMP!" echo KC9cXHIkLywiIik7IHByaW50ZiAiJXNcXHJcXG4iLCAkMH1cJyAiJGYiID4gIiRmLmNybGYiIDI+
>> "!B64TMP!" echo L2Rldi9udWxsICYmIG12ICIkZi5jcmxmIiAiJGYiIHx8IHJtIC1mICIkZi5jcmxmIicpCiAgICBh
>> "!B64TMP!" echo cCgnICBmaScpCiAgICBhcCgnZG9uZScpCiAgICBhcCgnJykKICAgICMgR2VuZXJhdGUgc2VjcmV0
>> "!B64TMP!" echo cwogICAgYXAoJ3NheSAiR2VuZXJhdGluZyBzZWN1cmUgY3JlZGVudGlhbHMuLi4iJykKICAgIGFw
>> "!B64TMP!" echo KCdnZW5rZXkoKSB7JykKICAgIGFwKCcgIGlmIGNvbW1hbmQgLXYgb3BlbnNzbCA+L2Rldi9udWxs
>> "!B64TMP!" echo IDI+JjE7IHRoZW4gb3BlbnNzbCByYW5kIC1oZXggMzInKQogICAgYXAoJyAgZWxzZSBoZWFkIC1j
>> "!B64TMP!" echo IDMyIC9kZXYvdXJhbmRvbSB8IG9kIC1BbiAtdHgxIHwgdHIgLWQgXCcgXFxuXCc7IGZpJykKICAg
>> "!B64TMP!" echo IGFwKCd9JykKICAgIGFwKCdTRUNSRVQ9IiQoZ2Vua2V5KSI7IEJVTEw9IiQoZ2Vua2V5KSI7IFBH
>> "!B64TMP!" echo UEFTUz0iJChnZW5rZXkpIjsgUkFCUEFTUz0iJChnZW5rZXkpIicpCiAgICBhcCgnJykKICAgICMg
>> "!B64TMP!" echo V3JpdGUgLmVudgogICAgYXAoJ3NheSAiV3JpdGluZyAuZW52IC4uLiInKQogICAgYXAoJ3snKQog
>> "!B64TMP!" echo ICAgYXAoJyAgZWNobyAiIyBMb2NhbCBTZWFyY2ggY29uZmlndXJhdGlvbiAtIGdlbmVyYXRlZCBi
>> "!B64TMP!" echo eSBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaCInKQogICAgYXAoJyAgZWNobyAiIyBFZGl0IHBvcnRz
>> "!B64TMP!" echo L0xMTSBoZXJlLCB0aGVuIHJ1biB1cGRhdGUuc2ggdG8gYXBwbHkuIicpCiAgICBhcCgnICBlY2hv
>> "!B64TMP!" echo JykKICAgIGFwKCcgIGVjaG8gIiMgLS0tLSBIb3N0IHBvcnRzIC0tLS0iJykKICAgIGFwKCcgIGVj
>> "!B64TMP!" echo aG8gIlNFQVJYTkdfUE9SVD0kU0VBUlhOR19QT1JUIicpCiAgICBhcCgnICBlY2hvICJGSVJFQ1JB
>> "!B64TMP!" echo V0xfUE9SVD0kRklSRUNSQVdMX1BPUlQiJykKICAgIGFwKCcgIGVjaG8nKQogICAgYXAoJyAgZWNo
>> "!B64TMP!" echo byAiIyAtLS0tIFNlYXJYTkcgaW5zdGFuY2Ugc2VjcmV0IC0tLS0iJykKICAgIGFwKCcgIGVjaG8g
>> "!B64TMP!" echo IlNFQVJYTkdfU0VDUkVUPSRTRUNSRVQiJykKICAgIGFwKCcgIGVjaG8nKQogICAgYXAoJyAgZWNo
>> "!B64TMP!" echo byAiIyAtLS0tIEZpcmVjcmF3bCBpbnRlcm5hbCBjcmVkZW50aWFscyAtLS0tIicpCiAgICBhcCgn
>> "!B64TMP!" echo ICBlY2hvICJCVUxMX0FVVEhfS0VZPSRCVUxMIicpCiAgICBhcCgnICBlY2hvICJQT1NUR1JFU19E
>> "!B64TMP!" echo Qj1maXJlY3Jhd2wiJykKICAgIGFwKCcgIGVjaG8gIlBPU1RHUkVTX1VTRVI9ZmlyZWNyYXdsIicp
>> "!B64TMP!" echo CiAgICBhcCgnICBlY2hvICJQT1NUR1JFU19QQVNTV09SRD0kUEdQQVNTIicpCiAgICBhcCgnICBl
>> "!B64TMP!" echo Y2hvICJSQUJCSVRNUV9VU0VSPWZpcmVjcmF3bCInKQogICAgYXAoJyAgZWNobyAiUkFCQklUTVFf
>> "!B64TMP!" echo UEFTU1dPUkQ9JFJBQlBBU1MiJykKICAgIGFwKCcgIGVjaG8nKQogICAgYXAoJyAgZWNobyAiTE9H
>> "!B64TMP!" echo R0lOR19MRVZFTD1pbmZvIicpCiAgICBhcCgnICBpZiBbIC1uICIkT1BFTkFJX0JBU0VfVVJMIiBd
>> "!B64TMP!" echo OyB0aGVuJykKICAgIGFwKCcgICAgZWNobycpCiAgICBhcCgnICAgIGVjaG8gIiMgLS0tLSBMb2Nh
>> "!B64TMP!" echo bCBMTE0gZm9yIEZpcmVjcmF3bCBBSSBmZWF0dXJlcyAtLS0tIicpCiAgICBhcCgnICAgIGVjaG8g
>> "!B64TMP!" echo Ik9QRU5BSV9CQVNFX1VSTD0kT1BFTkFJX0JBU0VfVVJMIicpCiAgICBhcCgnICAgIGVjaG8gIk9Q
>> "!B64TMP!" echo RU5BSV9BUElfS0VZPSRPUEVOQUlfQVBJX0tFWSInKQogICAgYXAoJyAgICBbIC1uICIkTU9ERUxf
>> "!B64TMP!" echo TkFNRSIgXSAmJiBlY2hvICJNT0RFTF9OQU1FPSRNT0RFTF9OQU1FIicpCiAgICBhcCgnICBmaScp
>> "!B64TMP!" echo CiAgICBhcCgnICBpZiBbIC1uICIkRkNfQVBJX0tFWSIgXTsgdGhlbicpCiAgICBhcCgnICAgIGVj
>> "!B64TMP!" echo aG8nKQogICAgYXAoJyAgICBlY2hvICIjIC0tLS0gRmlyZWNyYXdsIGFjY291bnQgKGNsb3VkIEFQ
>> "!B64TMP!" echo SSkgZm9yIGFjY291bnQtb25seSB0b29scyAtLS0tIicpCiAgICBhcCgnICAgIGVjaG8gIkZJUkVD
>> "!B64TMP!" echo UkFXTF9BUElfVVJMPSRGQ19BUElfVVJMIicpCiAgICBhcCgnICAgIGVjaG8gIkZJUkVDUkFXTF9B
>> "!B64TMP!" echo UElfS0VZPSRGQ19BUElfS0VZIicpCiAgICBhcCgnICBmaScpCiAgICBhcCgnfSA+ICIkVEFSR0VU
>> "!B64TMP!" echo Ly5lbnYiJykKICAgIGFwKCcnKQogICAgIyBJbmplY3Qgc2VjcmV0CiAgICBhcCgnc2F5ICJJbmpl
>> "!B64TMP!" echo Y3RpbmcgU2VhclhORyBzZWNyZXQgaW50byBzZXR0aW5ncy55bWwgLi4uIicpCiAgICBhcCgnU0ZJ
>> "!B64TMP!" echo TEU9IiRUQVJHRVQvY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sIicpCiAgICBhcCgnc2VkICJz
>> "!B64TMP!" echo L19fU0VBUlhOR19TRUNSRVRfUExBQ0VIT0xERVJfXy8kU0VDUkVULyIgIiRTRklMRSIgPiAiJFNG
>> "!B64TMP!" echo SUxFLnRtcCIgJiYgbXYgIiRTRklMRS50bXAiICIkU0ZJTEUiJykKICAgIGFwKCcnKQogICAgIyAt
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tCiAgICAjICBDb3JlLW9ubHkgdHJpbTogd2l0aG91dCBhIEZpcmVjcmF3bCBhY2Nv
>> "!B64TMP!" echo dW50LCByZW1vdmUgdGhlIDE5CiAgICAjICBhY2NvdW50LWdhdGVkIHNjcmlwdHMgZnJvbSB0aGUg
>> "!B64TMP!" echo YnVuZGxlZCBza2lsbCBhbmQgc3dhcCBpbiB0aGUKICAgICMgIGNvcmUtb25seSBTS0lMTC5tZCBz
>> "!B64TMP!" echo byB0aGUgaW5zdGFsbGVkIHNraWxsIG1hdGNoZXMgd2hhdCB3b3Jrcy4KICAgICMgLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LQogICAgYXAoJ2lmIFsgLXogIiRGQ19BUElfS0VZIiBdOyB0aGVuJykKICAgIGFwKCcgIHNheSAi
>> "!B64TMP!" echo SW5zdGFsbGluZyB0aGUgY29yZS1vbmx5IGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwgKG5vIEZpcmVj
>> "!B64TMP!" echo cmF3bCBhY2NvdW50KS4uLiInKQogICAgZm9yIG5hbWUgaW4gQUNDT1VOVF9UT09MUzoKICAgICAg
>> "!B64TMP!" echo ICBhcCgnICBybSAtZiAiJFRBUkdFVC9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvJyArIG5hbWUg
>> "!B64TMP!" echo KyAnIicpCiAgICBhcCgnICBpZiBbIC1mICIkVEFSR0VUL2xvY2FsLXdlYi1zZWFyY2gvU0tJTEwt
>> "!B64TMP!" echo Y29yZS5tZCIgXTsgdGhlbiBjcCAtZiAiJFRBUkdFVC9sb2NhbC13ZWItc2VhcmNoL1NLSUxMLWNv
>> "!B64TMP!" echo cmUubWQiICIkVEFSR0VUL2xvY2FsLXdlYi1zZWFyY2gvU0tJTEwubWQiOyBmaScpCiAgICBhcCgn
>> "!B64TMP!" echo ZmknKQogICAgYXAoJyMgU0tJTEwtY29yZS5tZCBpcyBhIGJ1aWxkLXRpbWUgdmFyaWFudCAtIG5l
>> "!B64TMP!" echo dmVyIHBhcnQgb2YgYW4gaW5zdGFsbGVkIHNraWxsLicpCiAgICBhcCgncm0gLWYgIiRUQVJHRVQv
>> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9TS0lMTC1jb3JlLm1kIicpCiAgICBhcCgnJykKICAgICMgLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLQogICAgIyAgSW5zdGFsbCB0aGUgYnVuZGxlZCBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNr
>> "!B64TMP!" echo aWxsIGludG8gdGhlIHVzZXIncyBza2lsbHMKICAgICMgIGRpcmVjdG9yeSAoYWRkL292ZXJyaWRl
>> "!B64TMP!" echo KSwgYW5kIHJlY29yZCB0aGUgaW5zdGFsbCBwYXRoIGhpbnQuCiAgICAjIC0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAg
>> "!B64TMP!" echo IGFwKCdzYXkgIkluc3RhbGxpbmcgdGhlIGxvY2FsLXdlYi1zZWFyY2ggYWdlbnQgc2tpbGwuLi4i
>> "!B64TMP!" echo JykKICAgIGFwKCdTS0lMTF9ESVI9IiRIT01FLy5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFy
>> "!B64TMP!" echo Y2giJykKICAgIGFwKCdybSAtcmYgIiRTS0lMTF9ESVIiJykKICAgIGFwKCdta2RpciAtcCAiJEhP
>> "!B64TMP!" echo TUUvLmFnZW50cy9za2lsbHMiJykKICAgIGFwKCdpZiBjcCAtciAiJFRBUkdFVC9sb2NhbC13ZWIt
>> "!B64TMP!" echo c2VhcmNoIiAiJFNLSUxMX0RJUiI7IHRoZW4nKQogICAgYXAoJyAgcHJpbnRmIFwnJXNcXG5cJyAi
>> "!B64TMP!" echo JFRBUkdFVCIgPiAiJFRBUkdFVC9sb2NhbC13ZWItc2VhcmNoL2luc3RhbGwtZGlyLnR4dCInKQog
>> "!B64TMP!" echo ICAgYXAoJyAgcHJpbnRmIFwnJXNcXG5cJyAiJFRBUkdFVCIgPiAiJFNLSUxMX0RJUi9pbnN0YWxs
>> "!B64TMP!" echo LWRpci50eHQiJykKICAgIGFwKCcgIHNheSAiICBBZ2VudCBza2lsbCBpbnN0YWxsZWQ6ICRTS0lM
>> "!B64TMP!" echo TF9ESVIiJykKICAgIGFwKCdlbHNlJykKICAgIGFwKCcgIHNheSAiICAke1lFTExPV31bV0FSTklO
>> "!B64TMP!" echo R10ke1JFU0VUfSBjb3VsZCBub3QgY29weSB0aGUgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCB0byAk
>> "!B64TMP!" echo U0tJTExfRElSIicpCiAgICBhcCgnZmknKQogICAgYXAoJycpCiAgICAjIElmIHdlIGxhdW5jaGVk
>> "!B64TMP!" echo IHRoZSBlbmdpbmUgYWJvdmUsIHdhaXQgZm9yIGl0IHRvIGNvbWUgb25saW5lIG5vdyAodGhlCiAg
>> "!B64TMP!" echo ICAjIHByb21wdHMgYWJvdmUgcmFuIHdoaWxlIGl0IHdhcyBib290aW5nIGluIHRoZSBiYWNrZ3Jv
>> "!B64TMP!" echo dW5kKS4KICAgIGFwKCdpZiBbICIkRU5HSU5FX0xBVU5DSEVEIiA9ICIxIiBdOyB0aGVuJykKICAg
>> "!B64TMP!" echo IGFwKCcgIHNheSAiV2FpdGluZyBmb3IgdGhlIERvY2tlciBlbmdpbmUgdG8gY29tZSBvbmxpbmUg
>> "!B64TMP!" echo LSB1cCB0byAke0RPQ0tFUl9XQUlUX1RJTUVPVVR9cy4uLiInKQogICAgYXAoJyAgRERfV0FJVD0w
>> "!B64TMP!" echo JykKICAgIGFwKCcgIHdoaWxlICEgZG9ja2VyIGluZm8gPi9kZXYvbnVsbCAyPiYxOyBkbycpCiAg
>> "!B64TMP!" echo ICBhcCgnICAgIHNsZWVwIDUnKQogICAgYXAoJyAgICBERF9XQUlUPSQoKEREX1dBSVQgKyA1KSkn
>> "!B64TMP!" echo KQogICAgYXAoJyAgICBpZiBbICIkRERfV0FJVCIgLWdlICIkRE9DS0VSX1dBSVRfVElNRU9VVCIg
>> "!B64TMP!" echo XTsgdGhlbicpCiAgICBhcCgnICAgICAgZXJyICJUaGUgRG9ja2VyIGVuZ2luZSBkaWQgbm90IGNv
>> "!B64TMP!" echo bWUgb25saW5lIHdpdGhpbiAke0RPQ0tFUl9XQUlUX1RJTUVPVVR9cy4iJykKICAgIGFwKCcgICAg
>> "!B64TMP!" echo ICBzYXkgIiAgQ2hlY2sgRG9ja2VyIERlc2t0b3Agb3I6IHN1ZG8gc3lzdGVtY3RsIHN0YXR1cyBk
>> "!B64TMP!" echo b2NrZXIiJykKICAgIGFwKCcgICAgICBzYXkgIiAgTGludXggcGVybWlzc2lvbiBkZW5pZWQgZnJv
>> "!B64TMP!" echo bSBkb2NrZXIgaW5mbz8gYWRkIHlvdXJzZWxmIHRvIHRoZSInKQogICAgYXAoJyAgICAgIHNheSAi
>> "!B64TMP!" echo ICBkb2NrZXIgZ3JvdXA6ICBzdWRvIHVzZXJtb2QgLWFHIGRvY2tlciAkVVNFUiAgKGxvZyBvdXQg
>> "!B64TMP!" echo YW5kIGJhY2sgaW4pIicpCiAgICBhcCgnICAgICAgc2F5ICIgIHRoZW4gc3RhcnQgRG9ja2VyIGFu
>> "!B64TMP!" echo ZCByZS1ydW4gdGhpcyBpbnN0YWxsZXIuIicpCiAgICBhcCgnICAgICAgZXhpdCAxJykKICAgIGFw
>> "!B64TMP!" echo KCcgICAgZmknKQogICAgYXAoJyAgICBpZiBbICQoKEREX1dBSVQgJSAxNSkpIC1lcSAwIF07IHRo
>> "!B64TMP!" echo ZW4gc2F5ICIgIC4uLiBzdGlsbCB3YWl0aW5nLCAke0REX1dBSVR9cyBlbGFwc2VkIjsgZmknKQog
>> "!B64TMP!" echo ICAgYXAoJyAgZG9uZScpCiAgICBhcCgnICBvayAiRG9ja2VyIGVuZ2luZSBpcyBvbmxpbmUgYWZ0
>> "!B64TMP!" echo ZXIgJHtERF9XQUlUfXMuIicpCiAgICBhcCgnZmknKQogICAgYXAoJycpCiAgICAjIFB1bGwgKyB1
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
>> "!B64TMP!" echo ICBsb2NhbC13ZWItc2VhcmNoIHNraWxsOiAgICAgICAgICAgICAgJEhPTUUvLmFnZW50cy9za2ls
>> "!B64TMP!" echo bHMvbG9jYWwtd2ViLXNlYXJjaCInKQogICAgYXAoJ2VjaG8nKQogICAgYXAoJ3NheSAiICBJZiB5
>> "!B64TMP!" echo b3VyIGFnZW50IHdhcyBhbHJlYWR5IHJ1bm5pbmcsIHJlc3RhcnQgaXQgc28gaXQgcGlja3MgdXAi
>> "!B64TMP!" echo JykKICAgIGFwKCdzYXkgIiAgdGhlIG5ldyBza2lsbC4iJykKICAgIGFwKCdlY2hvJykKICAgIGFw
>> "!B64TMP!" echo KCdzYXkgIiAgTWFuYWdlIHRoZSBzdGFjayB3aXRoIHRoZSBzY3JpcHRzIGluOiInKQogICAgYXAo
>> "!B64TMP!" echo J3NheSAiICAgICRUQVJHRVQiJykKICAgIGFwKCdzYXkgIiAgICAgIC4vcnVuLnNoICAgLi9zdG9w
>> "!B64TMP!" echo LnNoICAgLi91cGRhdGUuc2ggICAuL3VuaW5zdGFsbC5zaCInKQogICAgYXAoJ2VjaG8nKQogICAg
>> "!B64TMP!" echo YXAoJ3NheSAiICBTZWUgUkVBRE1FLm1kIGZvciBob3cgdG8gY29ubmVjdCB0aGlzIHRvIHlvdXIg
>> "!B64TMP!" echo QUkgbW9kZWxzIicpCiAgICBhcCgnc2F5ICIgIChsb2NhbC13ZWItc2VhcmNoIHNraWxsLCBMTSBT
>> "!B64TMP!" echo dHVkaW8sIE1DUCBzZXJ2ZXIsIGRpcmVjdCBwcm9tcHRpbmcsIGV0Yy4pLiInKQogICAgYXAoJ3Nh
>> "!B64TMP!" echo eSAiJHtHUkVFTn09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT0ke1JFU0VUfSInKQoKICAgIHJldHVybiAiXG4iLmpvaW4ob3V0KSArICJc
>> "!B64TMP!" echo biIKCgpkZWYgbWFpbigpOgogICAgIyBJTVBPUlRBTlQ6IHdyaXRlIHRoZSAuYmF0IHRvIGRpc2sg
>> "!B64TMP!" echo RklSU1QsIFRIRU4gZ2VuZXJhdGUgdGhlIC5zaC4KICAgICMgVGhlIC5zaCBlbWJlZHMgaW5zdGFs
>> "!B64TMP!" echo bC1sb2NhbC1zZWFyY2guYmF0IGFzIGEgaGVyZWRvYywgc28gaXQgbXVzdCByZWFkCiAgICAjIHRo
>> "!B64TMP!" echo ZSBmcmVzaGx5LXdyaXR0ZW4gLmJhdCAobm90IGEgc3RhbGUgcHJldmlvdXMtZ2VuZXJhdGlvbiBj
>> "!B64TMP!" echo b3B5KS4KICAgIGJhdCA9IGdlbl9iYXQoKQogICAgd2l0aCBvcGVuKG9zLnBhdGguam9pbihTUkMs
>> "!B64TMP!" echo ICJpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQiKSwgIndiIikgYXMgZjoKICAgICAgICBmLndyaXRl
>> "!B64TMP!" echo KGJhdC5lbmNvZGUoInV0Zi04IikpCiAgICBzaCA9IGdlbl9zaCgpCiAgICB3aXRoIG9wZW4ob3Mu
>> "!B64TMP!" echo cGF0aC5qb2luKFNSQywgImluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIiksICJ3YiIpIGFzIGY6CiAg
>> "!B64TMP!" echo ICAgICAgZi53cml0ZShzaC5lbmNvZGUoInV0Zi04IikpCiAgICBvcy5jaG1vZChvcy5wYXRoLmpv
>> "!B64TMP!" echo aW4oU1JDLCAiaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giKSwgMG83NTUpCiAgICBwcmludCgiV3Jv
>> "!B64TMP!" echo dGUgaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0ICglZCBieXRlcykiICUgbGVuKGJhdCkpCiAgICBw
>> "!B64TMP!" echo cmludCgiV3JvdGUgaW5zdGFsbC1sb2NhbC1zZWFyY2guc2ggICglZCBieXRlcykiICUgbGVuKHNo
>> "!B64TMP!" echo KSkKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg==
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
>> "!B64TMP!" echo dWxsIGxvY2FsLXNlYXJjaCBzb3VyY2UgdHJlZSAoNDQgZmlsZXM7IHRoZSBnZW5lcmF0ZWQgaW5z
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
>> "!B64TMP!" echo aCIsCiAgICAidXBkYXRlLnNoIiwKICAgICJ1bmluc3RhbGwuc2giLAogICAgImxvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gvU0tJTEwubWQiLAogICAgIyBjb3JlLW9ubHkgU0tJTEwubWQgdmFyaWFudDogdGhlIGlu
>> "!B64TMP!" echo c3RhbGxlcnMgc3dhcCBpdCBpbiBvdmVyIFNLSUxMLm1kCiAgICAjIHdoZW4gbm8gRmlyZWNyYXds
>> "!B64TMP!" echo IGFjY291bnQgaXMgY29uZmlndXJlZCAodGhlaXIgIkFkZCBhIEZpcmVjcmF3bAogICAgIyBhY2Nv
>> "!B64TMP!" echo dW50PyIgcXVlc3Rpb24gZGVmYXVsdHMgdG8gTikKICAgICJsb2NhbC13ZWItc2VhcmNoL1NLSUxM
>> "!B64TMP!" echo LWNvcmUubWQiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9jb25maWcucHkiLAogICAg
>> "!B64TMP!" echo ImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkiLAogICAgImxvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2gvc2NyaXB0cy9maXJlY3Jhd2xfYXBpLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo L3NjcmlwdHMvd2ViX3NlYXJjaC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dl
>> "!B64TMP!" echo Yl9zY3JhcGUucHkiLAogICAgIyAtLS0tIHRoZSAyNCBGaXJlY3Jhd2wgTUNQLWVxdWl2YWxlbnQg
>> "!B64TMP!" echo dG9vbHMgKHdlYl9zZWFyY2gvd2ViX3NjcmFwZSBhYm92ZSArIHRoZXNlIDIyKSAtLS0tCiAgICAi
>> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tYXAucHkiLAogICAgImxvY2FsLXdlYi1zZWFy
>> "!B64TMP!" echo Y2gvc2NyaXB0cy93ZWJfY3Jhd2wucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfY3Jhd2xfc3RhdHVzLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2Fn
>> "!B64TMP!" echo ZW50LnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2FnZW50X3N0YXR1cy5w
>> "!B64TMP!" echo eSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9pbnRlcmFjdC5weSIsCiAgICAi
>> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9pbnRlcmFjdF9zdG9wLnB5IiwKICAgICJsb2Nh
>> "!B64TMP!" echo bC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3BhcnNlLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo L3NjcmlwdHMvd2ViX21vbml0b3JfY3JlYXRlLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3Nj
>> "!B64TMP!" echo cmlwdHMvd2ViX21vbml0b3JfbGlzdC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9tb25pdG9yX2dldC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9t
>> "!B64TMP!" echo b25pdG9yX3VwZGF0ZS5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25p
>> "!B64TMP!" echo dG9yX2RlbGV0ZS5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9y
>> "!B64TMP!" echo X3J1bi5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9yX2NoZWNr
>> "!B64TMP!" echo cy5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9yX2NoZWNrLnB5
>> "!B64TMP!" echo IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3Jlc2VhcmNoX3NlYXJjaC5weSIs
>> "!B64TMP!" echo CiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9yZXNlYXJjaF9pbnNwZWN0LnB5IiwK
>> "!B64TMP!" echo ICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3Jlc2VhcmNoX3JlbGF0ZWQucHkiLAog
>> "!B64TMP!" echo ICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfcmVhZC5weSIsCiAgICAi
>> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9naXRodWJfc2VhcmNoLnB5IiwKICAgICJsb2Nh
>> "!B64TMP!" echo bC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2RldmVsb3Blcl9zZWFyY2gucHkiLApdCgpOX0ZJTEVT
>> "!B64TMP!" echo ID0gbGVuKFNPVVJDRV9GSUxFUykgKyBsZW4oUklHX0ZJTEVTKQoKCmRlZiByZWFkX3Jvb3QocmVs
>> "!B64TMP!" echo KToKICAgIHdpdGggb3Blbihvcy5wYXRoLmpvaW4oUk9PVCwgcmVsKSwgInJiIikgYXMgZjoKICAg
>> "!B64TMP!" echo ICAgICByZXR1cm4gZi5yZWFkKCkKCgpkZWYgcmVhZF9zcmMocmVsKToKICAgIHdpdGggb3Blbihv
>> "!B64TMP!" echo cy5wYXRoLmpvaW4oU1JDLCByZWwpLCAicmIiKSBhcyBmOgogICAgICAgIHJldHVybiBmLnJlYWQo
>> "!B64TMP!" echo KQoKCmRlZiBiNjRfY2h1bmtlZChkYXRhLCB3aWR0aD03Nik6CiAgICBzID0gYmFzZTY0LmI2NGVu
>> "!B64TMP!" echo Y29kZShkYXRhKS5kZWNvZGUoImFzY2lpIikKICAgIHJldHVybiBbc1tpOmkgKyB3aWR0aF0gZm9y
>> "!B64TMP!" echo IGkgaW4gcmFuZ2UoMCwgbGVuKHMpLCB3aWR0aCldCgoKZGVmIHRhZ19mb3IocmVsKToKICAgIHJl
>> "!B64TMP!" echo dHVybiAiRU9GXyIgKyAiIi5qb2luKGMgaWYgYy5pc2FsbnVtKCkgZWxzZSAiXyIgZm9yIGMgaW4g
>> "!B64TMP!" echo cmVsKS51cHBlcigpCgoKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQojICBXaW5kb3dzIHBhY2tlciAo
>> "!B64TMP!" echo LmJhdCkKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PQoKZGVmIGdlbl9iYXRfcGFja2VyKCk6CiAgICBv
>> "!B64TMP!" echo dXQgPSBbXQogICAgYXAgPSBvdXQuYXBwZW5kCgogICAgYXAoJ0BlY2hvIG9mZicpCiAgICBhcCgn
>> "!B64TMP!" echo c2V0bG9jYWwgZW5hYmxlRGVsYXllZEV4cGFuc2lvbicpCiAgICBhcCgnY2hjcCA2NTAwMSA+bnVs
>> "!B64TMP!" echo JykKICAgIGFwKCd0aXRsZSBMb2NhbCBTZWFyY2ggRGV2IFJpZyAtIFVucGFjaycpCiAgICBhcCgn
>> "!B64TMP!" echo JykKICAgIGFwKCdSRU0gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCdSRU0gIExvY2FsIFNl
>> "!B64TMP!" echo YXJjaCBERVYgUklHIHBhY2tlciAgLSAgV2luZG93cycpCiAgICBhcCgnUkVNID09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PScpCiAgICBhcCgnUkVNICBTZWxmLWNvbnRhaW5lZDogZW1iZWRzIHRoZSBjb21wbGV0
>> "!B64TMP!" echo ZSBidWlsZC90ZXN0IGVudmlyb25tZW50IGZvciB0aGUnKQogICAgYXAoJ1JFTSAgbG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoIGluc3RhbGxlcnM6JykKICAgIGFwKCdSRU0gICAgKiB0aGUgbG9jYWwtc2VhcmNoIHNvdXJj
>> "!B64TMP!" echo ZSB0cmVlICglZCBmaWxlcyknICUgbGVuKFNPVVJDRV9GSUxFUykpCiAgICBhcCgnUkVNICAgICog
>> "!B64TMP!" echo Z2VuX2luc3RhbGxlcnMucHkgLyBnZW5fcmlnLnB5ICh0aGUgdHdvIGdlbmVyYXRvcnMpJykKICAg
>> "!B64TMP!" echo IGFwKCdSRU0gICAgKiBldmVyeSB0ZXN0ICsgYnVpbGQgc2NyaXB0ICsgQlVJTEQubWQnKQogICAg
>> "!B64TMP!" echo YXAoJ1JFTSAgVW5wYWNrIGFueXdoZXJlLCB0aGVuIHJ1biBidWlsZC5iYXQgKG9yOiBweXRob24g
>> "!B64TMP!" echo Z2VuX2luc3RhbGxlcnMucHkpIHRvJykKICAgIGFwKCdSRU0gIHJlZ2VuZXJhdGUgdGhlIGluc3Rh
>> "!B64TMP!" echo bGxlcnMsIGFuZDogcHl0aG9uIGdlbl9yaWcucHkgdG8gcmVnZW5lcmF0ZSB0aGVzZScpCiAgICBh
>> "!B64TMP!" echo cCgnUkVNICBwYWNrZXJzIGJ5dGUtZm9yLWJ5dGUuJykKICAgIGFwKCdSRU0gPT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09JykKICAgIGFwKCcnKQogICAgYXAoJ2VjaG8gPT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCdlY2hvICAgTG9j
>> "!B64TMP!" echo YWwgU2VhcmNoIERFViBSSUcgIChidWlsZCArIHRlc3QgZW52aXJvbm1lbnQpJykKICAgIGFwKCdl
>> "!B64TMP!" echo Y2hvICAgVW5wYWNrcyBldmVyeXRoaW5nIG5lZWRlZCB0byByZWdlbmVyYXRlIGFuZCB2ZXJpZnkg
>> "!B64TMP!" echo dGhlJykKICAgIGFwKCdlY2hvICAgaW5zdGFsbC1sb2NhbC1zZWFyY2ggaW5zdGFsbGVycy4nKQog
>> "!B64TMP!" echo ICAgYXAoJ2VjaG8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09JykKICAgIGFwKCdlY2hvLicpCiAgICBhcCgnJykKICAgICMgUHJvbXB0
>> "!B64TMP!" echo cwogICAgYXAoJ3NldCAiREVGQVVMVF9UQVJHRVQ9JX5kcDBsb2NhbC1zZWFyY2gtZGV2IicpCiAg
>> "!B64TMP!" echo ICBhcCgnJykKICAgIGFwKCdlY2hvIC0tLSBTdGVwIDEgb2YgMzogVW5wYWNrIGxvY2F0aW9uIC0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLScpCiAgICBhcCgnZWNobyAgIERlZmF1bHQ6ICVERUZB
>> "!B64TMP!" echo VUxUX1RBUkdFVCUnKQogICAgYXAoJ3NldCAiVEFSR0VUPSInKQogICAgYXAoJ3NldCAvcCBUQVJH
>> "!B64TMP!" echo RVQ9IiAgVGFyZ2V0IGZvbGRlciBbcHJlc3MgRW50ZXIgZm9yIGRlZmF1bHRdOiAiJykKICAgIGFw
>> "!B64TMP!" echo KCdpZiAiIVRBUkdFVCEiPT0iIiBzZXQgIlRBUkdFVD0lREVGQVVMVF9UQVJHRVQlIicpCiAgICBh
>> "!B64TMP!" echo cCgnc2V0ICJUQVJHRVQ9IVRBUkdFVDoiPSEiJykKICAgIGFwKCdmb3IgJSVJIGluICgiIVRBUkdF
>> "!B64TMP!" echo VCEiKSBkbyBzZXQgIlRBUkdFVD0lJX5mSSInKQogICAgYXAoJ2VjaG8gICBVc2luZzogIVRBUkdF
>> "!B64TMP!" echo VCEnKQogICAgYXAoJ2VjaG8gICBeKGV4aXN0aW5nIGZpbGVzIGluIHRoZSB0YXJnZXQgZm9sZGVy
>> "!B64TMP!" echo IGFyZSBvdmVyd3JpdHRlbl4pJykKICAgIGFwKCdlY2hvLicpCiAgICBhcCgnJykKICAgIGFwKCdl
>> "!B64TMP!" echo Y2hvIC0tLSBTdGVwIDIgb2YgMzogQnVpbGQgbm93PyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLScpCiAgICBhcCgnZWNobyAgIEdlbmVyYXRlIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJh
>> "!B64TMP!" echo dC8uc2ggd2l0aCBQeXRob24gcmlnaHQgYWZ0ZXIgdW5wYWNraW5nPycpCiAgICBhcCgnc2V0ICJC
>> "!B64TMP!" echo VUlMRE5PVz0iJykKICAgIGFwKCdzZXQgL3AgQlVJTEROT1c9IiAgUnVuIHRoZSBpbnN0YWxsZXIg
>> "!B64TMP!" echo YnVpbGQgbm93PyBbWS9uXTogIicpCiAgICBhcCgnZWNoby4nKQogICAgYXAoJycpCiAgICBhcCgn
>> "!B64TMP!" echo ZWNobyAtLS0gU3RlcCAzIG9mIDM6IENvbmZpcm0gLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0nKQogICAgYXAoJ2VjaG8gICBXaWxsIHVucGFjayAlZCBmaWxlcyBpbnRvOiAhVEFS
>> "!B64TMP!" echo R0VUIScgJSBOX0ZJTEVTKQogICAgYXAoJ3NldCAiQ09ORklSTT0iJykKICAgIGFwKCdzZXQgL3Ag
>> "!B64TMP!" echo Q09ORklSTT0iUHJvY2VlZD8gW1kvbl06ICInKQogICAgYXAoJ2lmIC9pICIhQ09ORklSTSEiPT0i
>> "!B64TMP!" echo biIgKCBlY2hvIENhbmNlbGxlZC4gJiBwYXVzZSAmIGV4aXQgL2IgMCApJykKICAgIGFwKCcnKQog
>> "!B64TMP!" echo ICAgIyBGb2xkZXJzCiAgICBhcCgnaWYgbm90IGV4aXN0ICIhVEFSR0VUISIgbWtkaXIgIiFUQVJH
>> "!B64TMP!" echo RVQhIicpCiAgICBhcCgnaWYgbm90IGV4aXN0ICIhVEFSR0VUIVxcbG9jYWwtc2VhcmNoIiBta2Rp
>> "!B64TMP!" echo ciAiIVRBUkdFVCFcXGxvY2FsLXNlYXJjaCInKQogICAgYXAoJ2lmIG5vdCBleGlzdCAiIVRBUkdF
>> "!B64TMP!" echo VCFcXGxvY2FsLXNlYXJjaFxcY29uZmlnXFxzZWFyeG5nIiBta2RpciAiIVRBUkdFVCFcXGxvY2Fs
>> "!B64TMP!" echo LXNlYXJjaFxcY29uZmlnXFxzZWFyeG5nIicpCiAgICBhcCgnaWYgbm90IGV4aXN0ICIhVEFSR0VU
>> "!B64TMP!" echo IVxcbG9jYWwtc2VhcmNoXFxsb2NhbC13ZWItc2VhcmNoXFxzY3JpcHRzIiBta2RpciAiIVRBUkdF
>> "!B64TMP!" echo VCFcXGxvY2FsLXNlYXJjaFxcbG9jYWwtd2ViLXNlYXJjaFxcc2NyaXB0cyInKQogICAgYXAoJycp
>> "!B64TMP!" echo CiAgICBhcCgnZWNobyBVbnBhY2tpbmcgZmlsZXMuLi4nKQoKICAgIGRlZiBiNjRfYmxvY2sobGFi
>> "!B64TMP!" echo ZWwsIGRhdGEsIG91dF93aW4pOgogICAgICAgIGxpbmVzID0gYjY0X2NodW5rZWQoZGF0YSkKICAg
>> "!B64TMP!" echo ICAgICB0YWcgPSAiTFNSIiArIHN0cih6bGliLmNyYzMyKGxhYmVsLmVuY29kZSgidXRmLTgiKSkg
>> "!B64TMP!" echo JiAweEZGRkZGRkZGKQogICAgICAgIGFwKCcnKQogICAgICAgIGFwKCdSRU0gLS0tICcgKyBsYWJl
>> "!B64TMP!" echo bCArICcgLS0tJykKICAgICAgICBhcCgnc2V0ICJCNjRUTVA9JVRFTVAlXFwnICsgdGFnICsgJy5i
>> "!B64TMP!" echo NjQiJykKICAgICAgICBmaXJzdCA9IFRydWUKICAgICAgICBmb3IgbG4gaW4gbGluZXM6CiAgICAg
>> "!B64TMP!" echo ICAgICAgIGFwKCgnPiAnIGlmIGZpcnN0IGVsc2UgJz4+ICcpICsgJyIhQjY0VE1QISIgZWNobyAn
>> "!B64TMP!" echo ICsgbG4pCiAgICAgICAgICAgIGZpcnN0ID0gRmFsc2UKICAgICAgICBhcCgnc2V0ICJMU19CNjRf
>> "!B64TMP!" echo SU49IUI2NFRNUCEiJykKICAgICAgICBhcCgnc2V0ICJMU19CNjRfT1VUPScgKyBvdXRfd2luICsg
>> "!B64TMP!" echo JyInKQogICAgICAgIGFwKCdjYWxsIDpkZWNvZGVfYjY0JykKICAgICAgICBhcCgnZGVsIC9RICIh
>> "!B64TMP!" echo QjY0VE1QISIgPm51bCAyPiYxJykKCiAgICAjIGxvY2FsLXNlYXJjaCBzb3VyY2VzCiAgICBmb3Ig
>> "!B64TMP!" echo cmVsIGluIFNPVVJDRV9GSUxFUzoKICAgICAgICBsYWJlbCA9ICJsb2NhbC1zZWFyY2gvIiArIHJl
>> "!B64TMP!" echo bAogICAgICAgIGI2NF9ibG9jayhsYWJlbCwgcmVhZF9zcmMocmVsKSwgJyFUQVJHRVQhXFxsb2Nh
>> "!B64TMP!" echo bC1zZWFyY2hcXCcgKyByZWwucmVwbGFjZSgiLyIsICJcXCIpKQogICAgIyByaWcgZmlsZXMKICAg
>> "!B64TMP!" echo IGZvciByZWwgaW4gUklHX0ZJTEVTOgogICAgICAgIGI2NF9ibG9jayhyZWwsIHJlYWRfcm9vdChy
>> "!B64TMP!" echo ZWwpLCAnIVRBUkdFVCFcXCcgKyByZWwucmVwbGFjZSgiLyIsICJcXCIpKQoKICAgIGFwKCcnKQog
>> "!B64TMP!" echo ICAgYXAoJ1JFTSBLZWVwIGEgY29weSBvZiB0aGlzIHBhY2tlciBpbiB0aGUgdGFyZ2V0IHNvIHRo
>> "!B64TMP!" echo ZSByaWcgaXMgY29tcGxldGUuJykKICAgIGFwKCdjb3B5IC9ZICIlfmYwIiAiIVRBUkdFVCFcXGxv
>> "!B64TMP!" echo Y2FsLXNlYXJjaC1yaWcuYmF0IiA+bnVsIDI+JjEnKQogICAgYXAoJ2VjaG8gICBEb25lIC0gJWQg
>> "!B64TMP!" echo ZmlsZXMgKyB0aGlzIHBhY2tlci4nICUgTl9GSUxFUykKICAgIGFwKCcnKQogICAgIyBPcHRpb25h
>> "!B64TMP!" echo bCBidWlsZAogICAgYXAoJ2lmIC9pIG5vdCAiIUJVSUxETk9XISI9PSJuIiAoJykKICAgIGFwKCcg
>> "!B64TMP!" echo IHNldCAiUFk9IicpCiAgICBhcCgnICBweSAtMyAtYyAicHJpbnQoMSkiID5udWwgMj4mMScpCiAg
>> "!B64TMP!" echo ICBhcCgnICBpZiBub3QgZXJyb3JsZXZlbCAxIHNldCAiUFk9cHkgLTMiJykKICAgIGFwKCcgIGlm
>> "!B64TMP!" echo IG5vdCBkZWZpbmVkIFBZICgnKQogICAgYXAoJyAgICBweXRob24gLWMgInByaW50KDEpIiA+bnVs
>> "!B64TMP!" echo IDI+JjEnKQogICAgYXAoJyAgICBpZiBub3QgZXJyb3JsZXZlbCAxIHNldCAiUFk9cHl0aG9uIicp
>> "!B64TMP!" echo CiAgICBhcCgnICApJykKICAgIGFwKCcgIGlmIG5vdCBkZWZpbmVkIFBZICgnKQogICAgYXAoJyAg
>> "!B64TMP!" echo ICBweXRob24zIC1jICJwcmludCgxKSIgPm51bCAyPiYxJykKICAgIGFwKCcgICAgaWYgbm90IGVy
>> "!B64TMP!" echo cm9ybGV2ZWwgMSBzZXQgIlBZPXB5dGhvbjMiJykKICAgIGFwKCcgICknKQogICAgYXAoJyAgaWYg
>> "!B64TMP!" echo bm90IGRlZmluZWQgUFkgKCcpCiAgICBhcCgnICAgIGVjaG8uJykKICAgIGFwKCcgICAgZWNobyAg
>> "!B64TMP!" echo IFtXQVJOSU5HXSBQeXRob24gbm90IGZvdW5kIC0gc2tpcHBpbmcgdGhlIGJ1aWxkLicpCiAgICBh
>> "!B64TMP!" echo cCgnICAgIGVjaG8gICBJbnN0YWxsIFB5dGhvbiAzLjgrLCB0aGVuIHJ1biBidWlsZC5iYXQgaW4g
>> "!B64TMP!" echo dGhlIHRhcmdldCBmb2xkZXIuJykKICAgIGFwKCcgICkgZWxzZSAoJykKICAgIGFwKCcgICAgZWNo
>> "!B64TMP!" echo by4nKQogICAgYXAoJyAgICBlY2hvIEJ1aWxkaW5nIGluc3RhbGxlcnMgd2l0aCAhUFkhIC4uLicp
>> "!B64TMP!" echo CiAgICBhcCgnICAgIHB1c2hkICIhVEFSR0VUISInKQogICAgYXAoJyAgICAhUFkhIGdlbl9pbnN0
>> "!B64TMP!" echo YWxsZXJzLnB5JykKICAgIGFwKCcgICAgaWYgZXJyb3JsZXZlbCAxICgnKQogICAgYXAoJyAgICAg
>> "!B64TMP!" echo IHBvcGQnKQogICAgYXAoJyAgICAgIGVjaG8gICBbRVJST1JdIGdlbl9pbnN0YWxsZXJzLnB5IGZh
>> "!B64TMP!" echo aWxlZC4nKQogICAgYXAoJyAgICAgIHBhdXNlJykKICAgIGFwKCcgICAgICBleGl0IC9iIDEnKQog
>> "!B64TMP!" echo ICAgYXAoJyAgICApJykKICAgIGFwKCcgICAgcG9wZCcpCiAgICBhcCgnICAgIGVjaG8gICBJbnN0
>> "!B64TMP!" echo YWxsZXJzIHdyaXR0ZW4gdG8gIVRBUkdFVCFcXGxvY2FsLXNlYXJjaFxcJykKICAgIGFwKCcgICkn
>> "!B64TMP!" echo KQogICAgYXAoJyknKQogICAgYXAoJycpCiAgICAjIERvbmUKICAgIGFwKCdlY2hvLicpCiAgICBh
>> "!B64TMP!" echo cCgnZWNobyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT0nKQogICAgYXAoJ2VjaG8gICBEZXYgcmlnIHJlYWR5OiAhVEFSR0VUIScpCiAg
>> "!B64TMP!" echo ICBhcCgnZWNoby4nKQogICAgYXAoJ2VjaG8gICBOZXh0IHN0ZXBzIF4oc2VlIEJVSUxELm1kIGlu
>> "!B64TMP!" echo c2lkZV4pOicpCiAgICBhcCgnZWNobyAgICAgYnVpbGQuYmF0ICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo cmVidWlsZCBpbnN0YWxsZXJzICsgcGFja2VycyArIHRlc3RzJykKICAgIGFwKCdlY2hvICAgICBw
>> "!B64TMP!" echo eXRob24gZ2VuX2luc3RhbGxlcnMucHkgICAgICByZWJ1aWxkIGp1c3QgdGhlIGluc3RhbGxlcnMn
>> "!B64TMP!" echo KQogICAgYXAoJ2VjaG8gICAgIHB5dGhvbiBnZW5fcmlnLnB5ICAgICAgICAgICAgIHJlYnVpbGQg
>> "!B64TMP!" echo dGhlc2UgcGFja2VycycpCiAgICBhcCgnZWNobyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJ2VjaG8uJykKICAgIGFw
>> "!B64TMP!" echo KCdwYXVzZScpCiAgICBhcCgnZXhpdCAvYiAwJykKICAgIGFwKCcnKQogICAgYXAoJzpkZWNvZGVf
>> "!B64TMP!" echo YjY0JykKICAgIGFwKCdSRU0gICVlbnY6TFNfQjY0X0lOJSA9IC5iNjQgdGVtcCBmaWxlLCAlZW52
>> "!B64TMP!" echo OkxTX0I2NF9PVVQlID0gb3V0cHV0IHBhdGgnKQogICAgYXAoJ3Bvd2Vyc2hlbGwgLU5vUHJvZmls
>> "!B64TMP!" echo ZSAtQ29tbWFuZCAiJGluPSRlbnY6TFNfQjY0X0lOOyAkb3V0PSRlbnY6TFNfQjY0X09VVDsgW0lP
>> "!B64TMP!" echo LkZpbGVdOjpXcml0ZUFsbEJ5dGVzKCRvdXQsIFtDb252ZXJ0XTo6RnJvbUJhc2U2NFN0cmluZygo
>> "!B64TMP!" echo KEdldC1Db250ZW50IC1SYXcgJGluKSAtcmVwbGFjZSBcJ1xcc1wnLFwnXCcpKSkiJykKICAgIGFw
>> "!B64TMP!" echo KCdleGl0IC9iIDAnKQoKICAgIHJldHVybiAiXHJcbiIuam9pbihvdXQpICsgIlxyXG4iCgoKIyA9
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PQojICBMaW51eCAvIG1hY09TIHBhY2tlciAoLnNoKQojID09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09CgpkZWYgZ2VuX3NoX3BhY2tlcigpOgogICAgb3V0ID0gW10KICAgIGFw
>> "!B64TMP!" echo ID0gb3V0LmFwcGVuZAoKICAgIGFwKCcjIS91c3IvYmluL2VudiBiYXNoJykKICAgIGFwKCcjID09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCcjICBMb2NhbCBTZWFyY2ggREVWIFJJRyBwYWNr
>> "!B64TMP!" echo ZXIgIC0gIExpbnV4IC8gbWFjT1MgLyBHaXQgQmFzaCcpCiAgICBhcCgnIyA9PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PScpCiAgICBhcCgnIyAgU2VsZi1jb250YWluZWQ6IGVtYmVkcyB0aGUgY29tcGxldGUg
>> "!B64TMP!" echo YnVpbGQvdGVzdCBlbnZpcm9ubWVudCBmb3IgdGhlJykKICAgIGFwKCcjICBsb2NhbC1zZWFyY2gg
>> "!B64TMP!" echo aW5zdGFsbGVyczonKQogICAgYXAoJyMgICAgKiB0aGUgbG9jYWwtc2VhcmNoIHNvdXJjZSB0cmVl
>> "!B64TMP!" echo ICglZCBmaWxlcyknICUgbGVuKFNPVVJDRV9GSUxFUykpCiAgICBhcCgnIyAgICAqIGdlbl9pbnN0
>> "!B64TMP!" echo YWxsZXJzLnB5IC8gZ2VuX3JpZy5weSAodGhlIHR3byBnZW5lcmF0b3JzKScpCiAgICBhcCgnIyAg
>> "!B64TMP!" echo ICAqIGV2ZXJ5IHRlc3QgKyBidWlsZCBzY3JpcHQgKyBCVUlMRC5tZCcpCiAgICBhcCgnIyAgICAq
>> "!B64TMP!" echo IHRoZSBXaW5kb3dzIHBhY2tlciAobG9jYWwtc2VhcmNoLXJpZy5iYXQpJykKICAgIGFwKCcjICBT
>> "!B64TMP!" echo byB0aGlzIE9ORSBmaWxlIHJlcHJvZHVjZXMgdGhlIHdob2xlIHJpZyBhbnl3aGVyZSwgaW5jbHVk
>> "!B64TMP!" echo aW5nIGJvdGgnKQogICAgYXAoJyMgIHBhY2tlcnMuIFRoZSBpbnN0YWxsZXJzIHRoZW1zZWx2ZXMg
>> "!B64TMP!" echo YXJlIGdlbmVyYXRlZCBhZnRlciB1bnBhY2tpbmcnKQogICAgYXAoJyMgICh0aGlzIHNjcmlwdCBv
>> "!B64TMP!" echo ZmZlcnMgdG8gZG8gaXQpIHdpdGggZ2VuX2luc3RhbGxlcnMucHkuJykKICAgIGFwKCcjID09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09JykKICAgIGFwKCcnKQogICAgYXAoJ3NldCAtdScpCiAgICBhcCgnJykK
>> "!B64TMP!" echo ICAgIGFwKCdCT0xEPSJcXDAzM1sxbSI7IEdSRUVOPSJcXDAzM1szMm0iOyBZRUxMT1c9IlxcMDMz
>> "!B64TMP!" echo WzMzbSI7IFJFRD0iXFwwMzNbMzFtIjsgQ1lBTj0iXFwwMzNbMzZtIjsgUkVTRVQ9IlxcMDMzWzBt
>> "!B64TMP!" echo IicpCiAgICBhcCgnc2F5KCkgIHsgcHJpbnRmICIlYlxcbiIgIiQxIjsgfScpCiAgICBhcCgnZXJy
>> "!B64TMP!" echo KCkgIHsgcHJpbnRmICIlYltFUlJPUl0lYiAlc1xcbiIgIiRSRUQiICIkUkVTRVQiICIkMSIgPiYy
>> "!B64TMP!" echo OyB9JykKICAgIGFwKCdvaygpICAgeyBwcmludGYgIiViW09LXSViICVzXFxuIiAiJEdSRUVOIiAi
>> "!B64TMP!" echo JFJFU0VUIiAiJDEiOyB9JykKICAgIGFwKCdoZHIoKSAgeyBwcmludGYgIlxcbiViLS0tICVzIC0t
>> "!B64TMP!" echo LSViXFxuIiAiJENZQU4iICIkMSIgIiRSRVNFVCI7IH0nKQogICAgYXAoJ2xvd2VyKCkgeyBwcmlu
>> "!B64TMP!" echo dGYgXCclc1wnICIkMSIgfCB0ciBcJ1s6dXBwZXI6XVwnIFwnWzpsb3dlcjpdXCc7IH0gICMgYmFz
>> "!B64TMP!" echo aC0zLjIgKG1hY09TKSBzYWZlJykKICAgIGFwKCcnKQogICAgYXAoJ2NhdCA8PFwnQkFOTkVSXCcn
>> "!B64TMP!" echo KQogICAgYXAoJz09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PScpCiAgICBhcCgnICBMb2NhbCBTZWFyY2ggREVWIFJJRyAgKGJ1aWxkICsg
>> "!B64TMP!" echo dGVzdCBlbnZpcm9ubWVudCknKQogICAgYXAoJyAgVW5wYWNrcyBldmVyeXRoaW5nIG5lZWRlZCB0
>> "!B64TMP!" echo byByZWdlbmVyYXRlIGFuZCB2ZXJpZnkgdGhlJykKICAgIGFwKCcgIGluc3RhbGwtbG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoIGluc3RhbGxlcnMuJykKICAgIGFwKCc9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJ0JBTk5FUicpCiAgICBhcCgn
>> "!B64TMP!" echo JykKICAgIGFwKCdTQ1JJUFRfRElSPSIkKGNkICIkKGRpcm5hbWUgIiQwIikiICYmIHB3ZCkiJykK
>> "!B64TMP!" echo ICAgIGFwKCdERUZBVUxUX1RBUkdFVD0iJFNDUklQVF9ESVIvbG9jYWwtc2VhcmNoLWRldiInKQog
>> "!B64TMP!" echo ICAgYXAoJycpCiAgICBhcCgnaGRyICJTdGVwIDEgb2YgMzogVW5wYWNrIGxvY2F0aW9uIicpCiAg
>> "!B64TMP!" echo ICBhcCgnc2F5ICIgIERlZmF1bHQ6ICRERUZBVUxUX1RBUkdFVCInKQogICAgYXAoJ3ByaW50ZiAi
>> "!B64TMP!" echo ICBUYXJnZXQgZm9sZGVyIFtwcmVzcyBFbnRlciBmb3IgZGVmYXVsdF06ICInKQogICAgYXAoJ3Jl
>> "!B64TMP!" echo YWQgLXIgVEFSR0VUJykKICAgIGFwKCdbIC16ICIkVEFSR0VUIiBdICYmIFRBUkdFVD0iJERFRkFV
>> "!B64TMP!" echo TFRfVEFSR0VUIicpCiAgICBhcCgnaWYgWyAiJHtUQVJHRVQjXFx+fSIgIT0gIiRUQVJHRVQiIF07
>> "!B64TMP!" echo IHRoZW4gVEFSR0VUPSIkSE9NRSR7VEFSR0VUI1xcfn0iOyBmaSAgIyBQT1NJWCB0aWxkZSBleHBh
>> "!B64TMP!" echo bnNpb24nKQogICAgYXAoJ21rZGlyIC1wICIkVEFSR0VUIicpCiAgICBhcCgnVEFSR0VUPSIkKGNk
>> "!B64TMP!" echo ICIkVEFSR0VUIiAmJiBwd2QpIicpCiAgICBhcCgnc2F5ICIgIFVzaW5nOiAkVEFSR0VUIicpCiAg
>> "!B64TMP!" echo ICBhcCgnc2F5ICIgIChleGlzdGluZyBmaWxlcyBpbiB0aGUgdGFyZ2V0IGZvbGRlciBhcmUgb3Zl
>> "!B64TMP!" echo cndyaXR0ZW4pIicpCiAgICBhcCgnJykKICAgIGFwKCdoZHIgIlN0ZXAgMiBvZiAzOiBCdWlsZCBu
>> "!B64TMP!" echo b3c/IicpCiAgICBhcCgnc2F5ICIgIEdlbmVyYXRlIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdC8u
>> "!B64TMP!" echo c2ggd2l0aCBQeXRob24gcmlnaHQgYWZ0ZXIgdW5wYWNraW5nPyInKQogICAgYXAoJ3ByaW50ZiAi
>> "!B64TMP!" echo ICBSdW4gdGhlIGluc3RhbGxlciBidWlsZCBub3c/IFtZL25dOiAiJykKICAgIGFwKCdyZWFkIC1y
>> "!B64TMP!" echo IEJVSUxETk9XJykKICAgIGFwKCcnKQogICAgYXAoJ2hkciAiU3RlcCAzIG9mIDM6IENvbmZpcm0i
>> "!B64TMP!" echo JykKICAgIGFwKCdzYXkgIiAgV2lsbCB1bnBhY2sgJWQgZmlsZXMgaW50bzogJFRBUkdFVCInICUg
>> "!B64TMP!" echo Tl9GSUxFUykKICAgIGFwKCdwcmludGYgIlByb2NlZWQ/IFtZL25dOiAiJykKICAgIGFwKCdyZWFk
>> "!B64TMP!" echo IC1yIENPTkZJUk0nKQogICAgYXAoJ2lmIFsgIiQobG93ZXIgIiRDT05GSVJNIikiID0gIm4iIF07
>> "!B64TMP!" echo IHRoZW4gc2F5ICJDYW5jZWxsZWQuIjsgZXhpdCAwOyBmaScpCiAgICBhcCgnJykKICAgIGFwKCdt
>> "!B64TMP!" echo a2RpciAtcCAiJFRBUkdFVC9sb2NhbC1zZWFyY2gvY29uZmlnL3NlYXJ4bmciICIkVEFSR0VUL2xv
>> "!B64TMP!" echo Y2FsLXNlYXJjaC9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMiJykKICAgIGFwKCcnKQogICAgYXAo
>> "!B64TMP!" echo J3NheSAiVW5wYWNraW5nIGZpbGVzLi4uIicpCgogICAgZGVmIGhlcmVkb2NfYmxvY2socmVsX3Bh
>> "!B64TMP!" echo dGgsIGRhdGEpOgogICAgICAgIHRleHQgPSBkYXRhLmRlY29kZSgidXRmLTgiKQogICAgICAgICMg
>> "!B64TMP!" echo TEYtbm9ybWFsaXNlIHRoZSBoZXJlZG9jIGJvZHk7IHRoZSBhd2sgbG9vcCBiZWxvdyByZXN0b3Jl
>> "!B64TMP!" echo cyBDUkxGIGZvcgogICAgICAgICMgZXZlcnkgLmJhdCBmaWxlIGFmdGVyIHVucGFja2luZy4KICAg
>> "!B64TMP!" echo ICAgICB0ZXh0X2xmID0gdGV4dC5yZXBsYWNlKCJcclxuIiwgIlxuIikucmVwbGFjZSgiXHIiLCAi
>> "!B64TMP!" echo XG4iKQogICAgICAgIHRhZyA9IHRhZ19mb3IocmVsX3BhdGgpCiAgICAgICAgYXAoJycpCiAgICAg
>> "!B64TMP!" echo ICAgYXAoJyMgLS0tICcgKyByZWxfcGF0aCArICcgLS0tJykKICAgICAgICBhcCgnY2F0ID4gIiRU
>> "!B64TMP!" echo QVJHRVQvJyArIHJlbF9wYXRoICsgJyIgPDxcJycgKyB0YWcgKyAnXCcnKQogICAgICAgIGZvciBs
>> "!B64TMP!" echo aW5lIGluIHRleHRfbGYuc3BsaXRsaW5lcygpOgogICAgICAgICAgICBhcChsaW5lKQogICAgICAg
>> "!B64TMP!" echo IGFwKHRhZykKCiAgICAjIGxvY2FsLXNlYXJjaCBzb3VyY2VzCiAgICBmb3IgcmVsIGluIFNPVVJD
>> "!B64TMP!" echo RV9GSUxFUzoKICAgICAgICBoZXJlZG9jX2Jsb2NrKCJsb2NhbC1zZWFyY2gvIiArIHJlbCwgcmVh
>> "!B64TMP!" echo ZF9zcmMocmVsKSkKICAgICMgcmlnIGZpbGVzCiAgICBmb3IgcmVsIGluIFJJR19GSUxFUzoKICAg
>> "!B64TMP!" echo ICAgICBoZXJlZG9jX2Jsb2NrKHJlbCwgcmVhZF9yb290KHJlbCkpCiAgICAjIHRoZSBXaW5kb3dz
>> "!B64TMP!" echo IHBhY2tlciwgc28gdGhpcyBvbmUgZmlsZSByZXByb2R1Y2VzIHRoZSB3aG9sZSByaWcKICAgIGhl
>> "!B64TMP!" echo cmVkb2NfYmxvY2soImxvY2FsLXNlYXJjaC1yaWcuYmF0IiwgcmVhZF9yb290KCJsb2NhbC1zZWFy
>> "!B64TMP!" echo Y2gtcmlnLmJhdCIpKQoKICAgIGFwKCcnKQogICAgYXAoJyMgS2VlcCBhIGNvcHkgb2YgdGhpcyBw
>> "!B64TMP!" echo YWNrZXIgaW4gdGhlIHRhcmdldCBzbyB0aGUgcmlnIGlzIGNvbXBsZXRlLicpCiAgICBhcCgnY3Ag
>> "!B64TMP!" echo LWYgIiQwIiAiJFRBUkdFVC9sb2NhbC1zZWFyY2gtcmlnLnNoIicpCiAgICBhcCgnY2htb2QgK3gg
>> "!B64TMP!" echo IiRUQVJHRVQiLyouc2ggIiRUQVJHRVQiL2xvY2FsLXNlYXJjaC8qLnNoIDI+L2Rldi9udWxsIHx8
>> "!B64TMP!" echo IHRydWUnKQogICAgYXAoJycpCiAgICBhcCgnIyBSZXN0b3JlIENSTEYgbGluZSBlbmRpbmdzIGZv
>> "!B64TMP!" echo ciBldmVyeSAuYmF0IGZpbGUgKHRoZSBoZXJlZG9jcyBhYm92ZScpCiAgICBhcCgnIyB3cm90ZSBM
>> "!B64TMP!" echo RjsgYXdrIGlzIHVzZWQgaW5zdGVhZCBvZiBzZWQgc28gdGhpcyBhbHNvIHdvcmtzIG9uIG1hY09T
>> "!B64TMP!" echo KS4nKQogICAgYXAoJ2ZpbmQgIiRUQVJHRVQiIC10eXBlIGYgLW5hbWUgXCcqLmJhdFwnIDI+L2Rl
>> "!B64TMP!" echo di9udWxsIHwgd2hpbGUgSUZTPSByZWFkIC1yIGY7IGRvJykKICAgIGFwKCcgIGF3ayBcJ3tzdWIo
>> "!B64TMP!" echo L1xcciQvLCIiKTsgcHJpbnRmICIlc1xcclxcbiIsICQwfVwnICIkZiIgPiAiJGYuY3JsZiIgMj4v
>> "!B64TMP!" echo ZGV2L251bGwgXFwnKQogICAgYXAoJyAgICAmJiBtdiAiJGYuY3JsZiIgIiRmIiB8fCBybSAtZiAi
>> "!B64TMP!" echo JGYuY3JsZiInKQogICAgYXAoJ2RvbmUnKQogICAgYXAoJycpCiAgICBhcCgnb2sgIlVucGFja2Vk
>> "!B64TMP!" echo IHRoZSBkZXYgcmlnIGludG86ICRUQVJHRVQiJykKICAgIGFwKCcnKQogICAgIyBPcHRpb25hbCBi
>> "!B64TMP!" echo dWlsZAogICAgYXAoJ2lmIFsgIiQobG93ZXIgIiR7QlVJTEROT1c6LXl9IikiICE9ICJuIiBdOyB0
>> "!B64TMP!" echo aGVuJykKICAgIGFwKCcgIFBZPSIkKGNvbW1hbmQgLXYgcHl0aG9uMyB8fCBjb21tYW5kIC12IHB5
>> "!B64TMP!" echo dGhvbikiJykKICAgIGFwKCcgIGlmIFsgLW4gIiRQWSIgXTsgdGhlbicpCiAgICBhcCgnICAgIHNh
>> "!B64TMP!" echo eSAiQnVpbGRpbmcgaW5zdGFsbGVycyB3aXRoICRQWSAuLi4iJykKICAgIGFwKCcgICAgaWYgKGNk
>> "!B64TMP!" echo ICIkVEFSR0VUIiAmJiAiJFBZIiBnZW5faW5zdGFsbGVycy5weSk7IHRoZW4nKQogICAgYXAoJyAg
>> "!B64TMP!" echo ICAgIHNheSAiICBJbnN0YWxsZXJzIHdyaXR0ZW4gdG8gJFRBUkdFVC9sb2NhbC1zZWFyY2gvIicp
>> "!B64TMP!" echo CiAgICBhcCgnICAgIGVsc2UnKQogICAgYXAoJyAgICAgIGVyciAiZ2VuX2luc3RhbGxlcnMucHkg
>> "!B64TMP!" echo ZmFpbGVkIC0gc2VlIG91dHB1dCBhYm92ZS4iJykKICAgIGFwKCcgICAgZmknKQogICAgYXAoJyAg
>> "!B64TMP!" echo ZWxzZScpCiAgICBhcCgnICAgIHNheSAiICAke1lFTExPV31bV0FSTklOR10ke1JFU0VUfSBQeXRo
>> "!B64TMP!" echo b24gbm90IGZvdW5kIC0gc2tpcHBpbmcgdGhlIGJ1aWxkLiInKQogICAgYXAoJyAgICBzYXkgIiAg
>> "!B64TMP!" echo SW5zdGFsbCBQeXRob24gMy44KywgdGhlbiBydW4gLi9idWlsZC5zaCBpbiB0aGUgdGFyZ2V0IGZv
>> "!B64TMP!" echo bGRlci4iJykKICAgIGFwKCcgIGZpJykKICAgIGFwKCdmaScpCiAgICBhcCgnJykKICAgICMgRG9u
>> "!B64TMP!" echo ZQogICAgYXAoJ2VjaG8nKQogICAgYXAoJ3NheSAiJHtHUkVFTn09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0ke1JFU0VUfSInKQogICAg
>> "!B64TMP!" echo YXAoJ3NheSAiJHtHUkVFTn0gIERldiByaWcgcmVhZHk6ICRUQVJHRVQke1JFU0VUfSInKQogICAg
>> "!B64TMP!" echo YXAoJ2VjaG8nKQogICAgYXAoJ3NheSAiICBOZXh0IHN0ZXBzIChzZWUgQlVJTEQubWQgaW5zaWRl
>> "!B64TMP!" echo KToiJykKICAgIGFwKCdzYXkgIiAgICAuL2J1aWxkLnNoICAgICAgICAgICAgICAgICAgICByZWJ1
>> "!B64TMP!" echo aWxkIGluc3RhbGxlcnMgKyBwYWNrZXJzICsgdGVzdHMiJykKICAgIGFwKCdzYXkgIiAgICBweXRo
>> "!B64TMP!" echo b24zIGdlbl9pbnN0YWxsZXJzLnB5ICAgICByZWJ1aWxkIGp1c3QgdGhlIGluc3RhbGxlcnMiJykK
>> "!B64TMP!" echo ICAgIGFwKCdzYXkgIiAgICBweXRob24zIGdlbl9yaWcucHkgICAgICAgICAgICByZWJ1aWxkIHRo
>> "!B64TMP!" echo ZXNlIHBhY2tlcnMiJykKICAgIGFwKCdzYXkgIiR7R1JFRU59PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JHtSRVNFVH0iJykKCiAgICBy
>> "!B64TMP!" echo ZXR1cm4gIlxuIi5qb2luKG91dCkgKyAiXG4iCgoKZGVmIG1haW4oKToKICAgICMgV3JpdGUgdGhl
>> "!B64TMP!" echo IC5iYXQgcGFja2VyIEZJUlNUOiB0aGUgLnNoIHBhY2tlciBlbWJlZHMgaXQsIHNvIGl0IG11c3Qg
>> "!B64TMP!" echo cmVhZAogICAgIyB0aGUgZnJlc2hseS13cml0dGVuIGZpbGUgKG5vdCBhIHN0YWxlIHByZXZpb3Vz
>> "!B64TMP!" echo LWdlbmVyYXRpb24gY29weSkuCiAgICBiYXQgPSBnZW5fYmF0X3BhY2tlcigpCiAgICB3aXRoIG9w
>> "!B64TMP!" echo ZW4ob3MucGF0aC5qb2luKFJPT1QsICJsb2NhbC1zZWFyY2gtcmlnLmJhdCIpLCAid2IiKSBhcyBm
>> "!B64TMP!" echo OgogICAgICAgIGYud3JpdGUoYmF0LmVuY29kZSgidXRmLTgiKSkKICAgIHNoID0gZ2VuX3NoX3Bh
>> "!B64TMP!" echo Y2tlcigpCiAgICB3aXRoIG9wZW4ob3MucGF0aC5qb2luKFJPT1QsICJsb2NhbC1zZWFyY2gtcmln
>> "!B64TMP!" echo LnNoIiksICJ3YiIpIGFzIGY6CiAgICAgICAgZi53cml0ZShzaC5lbmNvZGUoInV0Zi04IikpCiAg
>> "!B64TMP!" echo ICBvcy5jaG1vZChvcy5wYXRoLmpvaW4oUk9PVCwgImxvY2FsLXNlYXJjaC1yaWcuc2giKSwgMG83
>> "!B64TMP!" echo NTUpCiAgICBwcmludCgiV3JvdGUgbG9jYWwtc2VhcmNoLXJpZy5iYXQgKCVkIGJ5dGVzKSIgJSBs
>> "!B64TMP!" echo ZW4oYmF0KSkKICAgIHByaW50KCJXcm90ZSBsb2NhbC1zZWFyY2gtcmlnLnNoICAoJWQgYnl0ZXMp
>> "!B64TMP!" echo IiAlIGxlbihzaCkpCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIG1haW4oKQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\gen_rig.py"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- extract-embedded.py ---
set "B64TMP=%TEMP%\LSR1004320646.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJFeHRyYWN0IHRoZSBmaWxlcyBlbWJlZGRlZCBpbiBh
>> "!B64TMP!" echo IGxvY2FsLXNlYXJjaCAuc2ggaW5zdGFsbGVyIG9yIHJpZyBwYWNrZXIuCgpXb3JrcyBvbjoKICAg
>> "!B64TMP!" echo IGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoICAgIC0+IGV4dHJhY3RzIHRoZSAyMCBsb2NhbC1zZWFy
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
>> "!B64TMP!" echo dW5pbnN0YWxsLnNoIiwKICAgICJsb2NhbC13ZWItc2VhcmNoL1NLSUxMLm1kIiwKICAgICJsb2Nh
>> "!B64TMP!" echo bC13ZWItc2VhcmNoL1NLSUxMLWNvcmUubWQiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0
>> "!B64TMP!" echo cy9jb25maWcucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9lbnN1cmVfc3RhY2su
>> "!B64TMP!" echo cHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9maXJlY3Jhd2xfYXBpLnB5IiwKICAg
>> "!B64TMP!" echo ICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3NlYXJjaC5weSIsCiAgICAibG9jYWwtd2Vi
>> "!B64TMP!" echo LXNlYXJjaC9zY3JpcHRzL3dlYl9zY3JhcGUucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2Ny
>> "!B64TMP!" echo aXB0cy93ZWJfbWFwLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2NyYXds
>> "!B64TMP!" echo LnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2NyYXdsX3N0YXR1cy5weSIs
>> "!B64TMP!" echo CiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9hZ2VudC5weSIsCiAgICAibG9jYWwt
>> "!B64TMP!" echo d2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9hZ2VudF9zdGF0dXMucHkiLAogICAgImxvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gvc2NyaXB0cy93ZWJfaW50ZXJhY3QucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2Ny
>> "!B64TMP!" echo aXB0cy93ZWJfaW50ZXJhY3Rfc3RvcC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9wYXJzZS5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9y
>> "!B64TMP!" echo X2NyZWF0ZS5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9yX2xp
>> "!B64TMP!" echo c3QucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9nZXQucHki
>> "!B64TMP!" echo LAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl91cGRhdGUucHkiLAog
>> "!B64TMP!" echo ICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9kZWxldGUucHkiLAogICAg
>> "!B64TMP!" echo ImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9ydW4ucHkiLAogICAgImxvY2Fs
>> "!B64TMP!" echo LXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9jaGVja3MucHkiLAogICAgImxvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9jaGVjay5weSIsCiAgICAibG9jYWwtd2ViLXNl
>> "!B64TMP!" echo YXJjaC9zY3JpcHRzL3dlYl9yZXNlYXJjaF9zZWFyY2gucHkiLAogICAgImxvY2FsLXdlYi1zZWFy
>> "!B64TMP!" echo Y2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aC9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo L3NjcmlwdHMvd2ViX3Jlc2VhcmNoX3JlYWQucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2Ny
>> "!B64TMP!" echo aXB0cy93ZWJfZ2l0aHViX3NlYXJjaC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9kZXZlbG9wZXJfc2VhcmNoLnB5IiwKXQoKZGVmIHJlYWQocmVsKToKICAgIHdpdGggb3Bl
>> "!B64TMP!" echo bihvcy5wYXRoLmpvaW4oU1JDLCByZWwpLCAicmIiKSBhcyBmOgogICAgICAgIHJldHVybiBmLnJl
>> "!B64TMP!" echo YWQoKQoKIyAtLS0tIGV4dHJhY3QgYmFzZTY0IGJsb2NrcyBmcm9tIHRoZSAuYmF0IC0tLS0KYmF0
>> "!B64TMP!" echo X3RleHQgPSBvcGVuKEJBVCwgInIiLCBlbmNvZGluZz0idXRmLTgiKS5yZWFkKCkKIyBBIGJsb2Nr
>> "!B64TMP!" echo IGxvb2tzIGxpa2U6CiMgICBSRU0gLS0tIDxyZWw+IC0tLQojICAgc2V0ICJORUVEX0I2ND0xIgoj
>> "!B64TMP!" echo ICAgLi4uCiMgICBzZXQgIkI2NFRNUD0lVEVNUCVcTFN4eHh4eHguYjY0IgojICAgPiAiIUI2NFRN
>> "!B64TMP!" echo UCEiIGVjaG8gTElORTEKIyAgID4+ICIhQjY0VE1QISIgZWNobyBMSU5FMgojICAgLi4uCiMgICBz
>> "!B64TMP!" echo ZXQgIkxTX0I2NF9JTj0uLi4iCmJsb2NrcyA9IHt9CmN1cl9yZWwgPSBOb25lCmN1cl9saW5lcyA9
>> "!B64TMP!" echo IFtdCmZvciBsaW5lIGluIGJhdF90ZXh0LnNwbGl0KCJcbiIpOgogICAgbSA9IHJlLm1hdGNoKHIn
>> "!B64TMP!" echo UkVNIC0tLSAoLis/KSAtLS0kJywgbGluZSkKICAgIGlmIG06CiAgICAgICAgaWYgY3VyX3JlbDoK
>> "!B64TMP!" echo ICAgICAgICAgICAgYmxvY2tzW2N1cl9yZWxdID0gY3VyX2xpbmVzCiAgICAgICAgY3VyX3JlbCA9
>> "!B64TMP!" echo IG0uZ3JvdXAoMSkKICAgICAgICBjdXJfbGluZXMgPSBbXQogICAgICAgIGNvbnRpbnVlCiAgICBt
>> "!B64TMP!" echo MiA9IHJlLm1hdGNoKHInXHMqPj4/XHMqIiFCNjRUTVAhIlxzK2VjaG9ccysoLispJCcsIGxpbmUp
>> "!B64TMP!" echo CiAgICBpZiBtMiBhbmQgY3VyX3JlbDoKICAgICAgICBjdXJfbGluZXMuYXBwZW5kKG0yLmdyb3Vw
>> "!B64TMP!" echo KDEpKQppZiBjdXJfcmVsOgogICAgYmxvY2tzW2N1cl9yZWxdID0gY3VyX2xpbmVzCgpwcmludCgi
>> "!B64TMP!" echo Rm91bmQgJWQgZW1iZWRkZWQgYmFzZTY0IGJsb2NrcyBpbiAuYmF0IiAlIGxlbihibG9ja3MpKQpv
>> "!B64TMP!" echo ayA9IFRydWUKZm9yIHJlbCBpbiBGSUxFUzoKICAgIG9yaWcgPSByZWFkKHJlbCkKICAgIGlmIHJl
>> "!B64TMP!" echo bCBub3QgaW4gYmxvY2tzOgogICAgICAgIHByaW50KCIgIFtNSVNTXSAlLTMycyA6IG5vIGJhc2U2
>> "!B64TMP!" echo NCBibG9jayBpbiAuYmF0IiAlIHJlbCkKICAgICAgICBvayA9IEZhbHNlCiAgICAgICAgY29udGlu
>> "!B64TMP!" echo dWUKICAgICMgY29uY2F0ZW5hdGUgYW5kIHN0cmlwIHdoaXRlc3BhY2UgKG1pcnJvcnMgUFMgLXJl
>> "!B64TMP!" echo cGxhY2UgJ1xzJywnJykKICAgIGpvaW5lZCA9ICIiLmpvaW4oYmxvY2tzW3JlbF0pCiAgICB0cnk6
>> "!B64TMP!" echo CiAgICAgICAgZGVjID0gYmFzZTY0LmI2NGRlY29kZShqb2luZWQpCiAgICBleGNlcHQgRXhjZXB0
>> "!B64TMP!" echo aW9uIGFzIGU6CiAgICAgICAgcHJpbnQoIiAgW0ZBSUxdICUtMzJzIDogYjY0IGRlY29kZSBlcnJv
>> "!B64TMP!" echo cjogJXMiICUgKHJlbCwgZSkpCiAgICAgICAgb2sgPSBGYWxzZQogICAgICAgIGNvbnRpbnVlCiAg
>> "!B64TMP!" echo ICBpZiBkZWMgPT0gb3JpZzoKICAgICAgICBwcmludCgiICBbT0tdICAgJS0zMnMgOiAlZCBieXRl
>> "!B64TMP!" echo cyByb3VuZC10cmlwIE9LIiAlIChyZWwsIGxlbihvcmlnKSkpCiAgICBlbHNlOgogICAgICAgIHBy
>> "!B64TMP!" echo aW50KCIgIFtGQUlMXSAlLTMycyA6IGRlY29kZWQgJWQgYnl0ZXMgIT0gb3JpZ2luYWwgJWQgYnl0
>> "!B64TMP!" echo ZXMiICUgKHJlbCwgbGVuKGRlYyksIGxlbihvcmlnKSkpCiAgICAgICAgb2sgPSBGYWxzZQoKIyAt
>> "!B64TMP!" echo LS0tIGNtZC5leGUgYmxvY2stcGFyZW4gc2FmZXR5IGNoZWNrIG9uIHRoZSAuYmF0IGxvZ2ljIGxp
>> "!B64TMP!" echo bmVzIC0tLS0KIyBSZWFsIGNtZC5leGUgcnVsZSAodmVyaWZpZWQgYWdhaW5zdCBhIHJlYWwgY21k
>> "!B64TMP!" echo LmV4ZSBpbXBsZW1lbnRhdGlvbik6CiMgICAqIGFuIHVucXVvdGVkL3VuZXNjYXBlZCAiKCIgaW4g
>> "!B64TMP!" echo ZWNobyB0ZXh0IGlzIElORVJUIChsaXRlcmFsIHRleHQpLAojICAgKiBidXQgYW4gdW5xdW90ZWQv
>> "!B64TMP!" echo dW5lc2NhcGVkICIpIiBJTlNJREUgYSBwYXJlbnRoZXNpemVkIGJsb2NrIGlzCiMgICAgIFNUUlVD
>> "!B64TMP!" echo VFVSQUw6IGl0IGNsb3NlcyB0aGUgYmxvY2sgYXQgdGhhdCBwb2ludC4gSWYgdGhlICIpIiBpcyBp
>> "!B64TMP!" echo biB0aGUKIyAgICAgbWlkZGxlIG9mIGEgY29tbWFuZCdzIHRleHQsIHRoZSByZW1haW5kZXIgb2Yg
>> "!B64TMP!" echo dGhlIHN0YXRlbWVudCBiZWNvbWVzCiMgICAgIHRvcC1sZXZlbCBnYXJiYWdlIC0+ICJGT1Igd2Fz
>> "!B64TMP!" echo IHVuZXhwZWN0ZWQgYXQgdGhpcyB0aW1lIiAob3Igc2ltaWxhcikKIyAgICAgLT4gY21kLmV4ZSBh
>> "!B64TMP!" echo Ym9ydHMgdGhlIGJhdGNoIGFuZCB0aGUgd2luZG93IGNsb3Nlcy4KIyBTbzogd2hpbGUgYSBibG9j
>> "!B64TMP!" echo ayBpcyBvcGVuLCBldmVyeSB1bnF1b3RlZC91bmVzY2FwZWQgIikiIG11c3QgYmUgYQojIGxlZ2l0
>> "!B64TMP!" echo aW1hdGUgY2xvc2VyOiBhICIpIi1saW5lLCAiKSBlbHNlICgiLCBvciBmb2xsb3dlZCBieSBkby8m
>> "!B64TMP!" echo L3wvRU9MLgpkZWYgX3VucXVvdGVkX3BhcmVucyhsaW5lKToKICAgIG91dCA9IFtdCiAgICBqID0g
>> "!B64TMP!" echo MDsgaW5xID0gRmFsc2UKICAgIHdoaWxlIGogPCBsZW4obGluZSk6CiAgICAgICAgYyA9IGxpbmVb
>> "!B64TMP!" echo al0KICAgICAgICBpZiBjID09ICJeIjoKICAgICAgICAgICAgaiArPSAyOyBjb250aW51ZQogICAg
>> "!B64TMP!" echo ICAgIGlmIGMgPT0gJyInOgogICAgICAgICAgICBpbnEgPSBub3QgaW5xOyBqICs9IDE7IGNvbnRp
>> "!B64TMP!" echo bnVlCiAgICAgICAgaWYgbm90IGlucSBhbmQgYyBpbiAiKCkiOgogICAgICAgICAgICBvdXQuYXBw
>> "!B64TMP!" echo ZW5kKChqLCBjKSkKICAgICAgICBqICs9IDEKICAgIHJldHVybiBvdXQKCl9jbG9zZV9jb250ID0g
>> "!B64TMP!" echo cmUuY29tcGlsZShyJ14oZWxzZVxifGRvXGJ8JnxcfHxyZW1cYnw6OiknLCByZS5JKQpiNjRsaW5l
>> "!B64TMP!" echo ID0gcmUuY29tcGlsZShyJ1xzKj4+P1xzKiI/IT9CNjRUTVAhPyI/XHMrZWNob1xzKycpCnJlbWxp
>> "!B64TMP!" echo bmUgPSByZS5jb21waWxlKHInXlxzKihSRU1cYnw6OiknLCByZS5JKQpiYXRfbGluZXMgPSBiYXRf
>> "!B64TMP!" echo dGV4dC5zcGxpdCgiXG4iKQpwYXJlbl9iYWQgPSBbXQpkZXB0aCA9IDAKZm9yIGksIGxpbmUgaW4g
>> "!B64TMP!" echo ZW51bWVyYXRlKGJhdF9saW5lcyk6CiAgICBpZiBiNjRsaW5lLm1hdGNoKGxpbmUpIG9yIHJlbWxp
>> "!B64TMP!" echo bmUubWF0Y2gobGluZSkgb3Igbm90IGxpbmUuc3RyaXAoKToKICAgICAgICBjb250aW51ZQogICAg
>> "!B64TMP!" echo IyBza2lwIGVtYmVkZGVkLWJhc2U2NCB0ZW1wLWZpbGUgd3JpdGVzCiAgICBwcyA9IF91bnF1b3Rl
>> "!B64TMP!" echo ZF9wYXJlbnMobGluZSkKICAgIGNsb3NlcyA9IFtwIGZvciBwIGluIHBzIGlmIHBbMV0gPT0gIiki
>> "!B64TMP!" echo XQogICAgb3BlbnMgPSBsZW4oW3AgZm9yIHAgaW4gcHMgaWYgcFsxXSA9PSAiKCJdKQogICAgIyBz
>> "!B64TMP!" echo dHJ1Y3R1cmFsIG9wZW5zOiAiKCIgYXQgZW5kIG9mIGxpbmUgKGlmL2Zvci9kbyBibG9ja3MpICsg
>> "!B64TMP!" echo aW5saW5lCiAgICAjIGZvci1zZXQvZG8gb3BlbnMgKCJpbiAoIiwgImRvICgiKQogICAgc3RydWN0
>> "!B64TMP!" echo dXJhbF9vcGVucyA9IDAKICAgIGlmIGxpbmUucnN0cmlwKCkuZW5kc3dpdGgoIigiKToKICAgICAg
>> "!B64TMP!" echo ICBzdHJ1Y3R1cmFsX29wZW5zICs9IDEKICAgIGlubGluZSA9IGxlbihyZS5maW5kYWxsKHIiXGJp
>> "!B64TMP!" echo blxzKlwoIiwgbGluZSkpICsgbGVuKHJlLmZpbmRhbGwociJcYmRvXHMqXCgiLCBsaW5lKSkKICAg
>> "!B64TMP!" echo IGlmIGxpbmUucnN0cmlwKCkuZW5kc3dpdGgoIigiKSBhbmQgaW5saW5lOgogICAgICAgIGlubGlu
>> "!B64TMP!" echo ZSA9IG1heCgwLCBpbmxpbmUgLSAxKQogICAgc3RydWN0dXJhbF9vcGVucyArPSBpbmxpbmUKICAg
>> "!B64TMP!" echo IGlmIGRlcHRoID4gMCBhbmQgY2xvc2VzOgogICAgICAgIGZvciBwb3MsIF9jaCBpbiBjbG9zZXM6
>> "!B64TMP!" echo CiAgICAgICAgICAgIGFmdGVyID0gbGluZVtwb3MgKyAxOl0ubHN0cmlwKCkKICAgICAgICAgICAg
>> "!B64TMP!" echo aWYgYWZ0ZXIgPT0gIiIgb3IgX2Nsb3NlX2NvbnQubWF0Y2goYWZ0ZXIpOgogICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgY29udGludWUgICMgbGVnaXRpbWF0ZSBjbG9zZXIKICAgICAgICAgICAgcGFyZW5fYmFkLmFw
>> "!B64TMP!" echo cGVuZCgoaSArIDEsIGxpbmUuc3RyaXAoKSkpCiAgICAgICAgICAgIGJyZWFrCiAgICBkZXB0aCAr
>> "!B64TMP!" echo PSBzdHJ1Y3R1cmFsX29wZW5zIC0gbGVuKGNsb3NlcykKICAgIGlmIGRlcHRoIDwgMDoKICAgICAg
>> "!B64TMP!" echo ICBkZXB0aCA9IDAgICMgdG9wLWxldmVsICIpIiBpbiBlY2hvIHRleHQgaXMgYSBsaXRlcmFsLCBo
>> "!B64TMP!" echo YXJtbGVzcwppZiBwYXJlbl9iYWQ6CiAgICBwcmludCgpCiAgICBwcmludCgiW0ZBSUxdIHVuZXNj
>> "!B64TMP!" echo YXBlZCAnKScgaW5zaWRlIGJsb2NrcyAoa2lsbHMgcmVhbCBjbWQuZXhlKToiKQogICAgZm9yIGxu
>> "!B64TMP!" echo LCB0eHQgaW4gcGFyZW5fYmFkOgogICAgICAgIHByaW50KCIgIEwlZDogJXMiICUgKGxuLCB0eHQp
>> "!B64TMP!" echo KQogICAgb2sgPSBGYWxzZQplbHNlOgogICAgcHJpbnQoInBhcmVuIGNoZWNrOiBubyB1bmVzY2Fw
>> "!B64TMP!" echo ZWQgJyknIGluc2lkZSBibG9ja3MgKGNtZC1zYWZlKSIpCgpwcmludCgpCnByaW50KCJBTEwgR09P
>> "!B64TMP!" echo RCIgaWYgb2sgZWxzZSAiRkFJTFVSRVMgUFJFU0VOVCIpCmltcG9ydCBzeXMKc3lzLmV4aXQoMCBp
>> "!B64TMP!" echo ZiBvayBlbHNlIDEpCg==
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
>> "!B64TMP!" echo cC5zaCIsICJ1cGRhdGUuc2giLCAidW5pbnN0YWxsLnNoIiwKICAgICJsb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo L1NLSUxMLm1kIiwKICAgICJsb2NhbC13ZWItc2VhcmNoL1NLSUxMLWNvcmUubWQiLAogICAgImxv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9jb25maWcucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gv
>> "!B64TMP!" echo c2NyaXB0cy9lbnN1cmVfc3RhY2sucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9m
>> "!B64TMP!" echo aXJlY3Jhd2xfYXBpLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3NlYXJj
>> "!B64TMP!" echo aC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9zY3JhcGUucHkiLAogICAg
>> "!B64TMP!" echo ImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbWFwLnB5IiwKICAgICJsb2NhbC13ZWItc2Vh
>> "!B64TMP!" echo cmNoL3NjcmlwdHMvd2ViX2NyYXdsLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMv
>> "!B64TMP!" echo d2ViX2NyYXdsX3N0YXR1cy5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9h
>> "!B64TMP!" echo Z2VudC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9hZ2VudF9zdGF0dXMu
>> "!B64TMP!" echo cHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfaW50ZXJhY3QucHkiLAogICAg
>> "!B64TMP!" echo ImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfaW50ZXJhY3Rfc3RvcC5weSIsCiAgICAibG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9wYXJzZS5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aC9zY3JpcHRzL3dlYl9tb25pdG9yX2NyZWF0ZS5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9z
>> "!B64TMP!" echo Y3JpcHRzL3dlYl9tb25pdG9yX2xpc3QucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfbW9uaXRvcl9nZXQucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJf
>> "!B64TMP!" echo bW9uaXRvcl91cGRhdGUucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9u
>> "!B64TMP!" echo aXRvcl9kZWxldGUucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRv
>> "!B64TMP!" echo cl9ydW4ucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9jaGVj
>> "!B64TMP!" echo a3MucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9jaGVjay5w
>> "!B64TMP!" echo eSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9yZXNlYXJjaF9zZWFyY2gucHki
>> "!B64TMP!" echo LAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSIs
>> "!B64TMP!" echo CiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IiwK
>> "!B64TMP!" echo ICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3Jlc2VhcmNoX3JlYWQucHkiLAogICAg
>> "!B64TMP!" echo ImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfZ2l0aHViX3NlYXJjaC5weSIsCiAgICAibG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9kZXZlbG9wZXJfc2VhcmNoLnB5IiwKICAgICJpbnN0
>> "!B64TMP!" echo YWxsLWxvY2FsLXNlYXJjaC5iYXQiLApdCgpkZWYgcmVhZChyZWwpOgogICAgd2l0aCBvcGVuKG9z
>> "!B64TMP!" echo LnBhdGguam9pbihTUkMsIHJlbCksICJyYiIpIGFzIGY6CiAgICAgICAgcmV0dXJuIGYucmVhZCgp
>> "!B64TMP!" echo CgojIEZpbmQgYmxvY2tzIG9mIHRoZSBmb3JtOgojICAgY2F0ID4gIiRUQVJHRVQvPHJlbD4iIDw8
>> "!B64TMP!" echo JzxUQUc+JwojICAgPGJvZHk+CiMgICA8VEFHPgpoZXJlZG9jcyA9IHt9CmxpbmVzID0gdGV4dC5z
>> "!B64TMP!" echo cGxpdCgiXG4iKQppID0gMAp3aGlsZSBpIDwgbGVuKGxpbmVzKToKICAgIG0gPSByZS5tYXRjaChy
>> "!B64TMP!" echo IlxzKmNhdCA+IFwiXCRUQVJHRVQvKC4rPylcIiA8PCcoW0EtWjAtOV9dKyknJCIsIGxpbmVzW2ld
>> "!B64TMP!" echo KQogICAgaWYgbToKICAgICAgICByZWwsIHRhZyA9IG0uZ3JvdXAoMSksIG0uZ3JvdXAoMikKICAg
>> "!B64TMP!" echo ICAgICBib2R5X3N0YXJ0ID0gaSArIDEKICAgICAgICAjIGZpbmQgY2xvc2luZyB0YWcKICAgICAg
>> "!B64TMP!" echo ICBqID0gYm9keV9zdGFydAogICAgICAgIHdoaWxlIGogPCBsZW4obGluZXMpIGFuZCBsaW5lc1tq
>> "!B64TMP!" echo XSAhPSB0YWc6CiAgICAgICAgICAgIGogKz0gMQogICAgICAgIGJvZHkgPSAiXG4iLmpvaW4obGlu
>> "!B64TMP!" echo ZXNbYm9keV9zdGFydDpqXSkKICAgICAgICAjIGV2ZXJ5IGhlcmVkb2MgbGluZSAoaW5jbHVkaW5n
>> "!B64TMP!" echo IHRoZSBsYXN0KSBpcyB3cml0dGVuIHdpdGggYSB0cmFpbGluZwogICAgICAgICMgbmV3bGluZSBi
>> "!B64TMP!" echo eSB0aGUgc2hlbGwsIHNvIGFwcGVuZCBpdCBiYWNrIGFmdGVyIHRoZSBqb2luLgogICAgICAgIGlm
>> "!B64TMP!" echo IGJvZHlfc3RhcnQgPD0gajoKICAgICAgICAgICAgYm9keSArPSAiXG4iCiAgICAgICAgaGVyZWRv
>> "!B64TMP!" echo Y3NbcmVsXSA9IGJvZHkKICAgICAgICBpID0gaiArIDEKICAgIGVsc2U6CiAgICAgICAgaSArPSAx
>> "!B64TMP!" echo CgpwcmludCgiRm91bmQgJWQgaGVyZWRvY3MgaW4gLnNoIiAlIGxlbihoZXJlZG9jcykpCm9rID0g
>> "!B64TMP!" echo VHJ1ZQpmb3IgcmVsIGluIEZJTEVTOgogICAgb3JpZyA9IHJlYWQocmVsKS5kZWNvZGUoInV0Zi04
>> "!B64TMP!" echo IikKICAgIGlmIHJlbCBub3QgaW4gaGVyZWRvY3M6CiAgICAgICAgcHJpbnQoIiAgW01JU1NdICUt
>> "!B64TMP!" echo MzJzIiAlIHJlbCkKICAgICAgICBvayA9IEZhbHNlCiAgICAgICAgY29udGludWUKICAgICMgQ29t
>> "!B64TMP!" echo cGFyZSBjb250ZW50IGlnbm9yaW5nIGxpbmUtZW5kaW5nIGRpZmZlcmVuY2VzOiB0aGUgLnNoIGlu
>> "!B64TMP!" echo c3RhbGxlcgogICAgIyB3cml0ZXMgLmJhdCBmaWxlcyB2aWEgaGVyZWRvYyAoTEYpIGFuZCB0aGVu
>> "!B64TMP!" echo IGEgcnVudGltZSBDUkxGLWNvbnZlcnNpb24KICAgICMgbG9vcCBjb252ZXJ0cyB0aGVtIHRvIENS
>> "!B64TMP!" echo TEYuIFNvIHRoZSBoZXJlZG9jIGJvZHkgaGFzIExGIHdoZXJlIHRoZQogICAgIyBvcmlnaW5hbCAu
>> "!B64TMP!" echo YmF0IGhhcyBDUkxGIC0tIHRoaXMgaXMgZXhwZWN0ZWQgYW5kIGNvcnJlY3QuCiAgICBhID0gaGVy
>> "!B64TMP!" echo ZWRvY3NbcmVsXS5yZXBsYWNlKCJcclxuIiwgIlxuIikKICAgIGIgPSBvcmlnLnJlcGxhY2UoIlxy
>> "!B64TMP!" echo XG4iLCAiXG4iKQogICAgaWYgYSA9PSBiOgogICAgICAgIHByaW50KCIgIFtPS10gICAlLTMycyA6
>> "!B64TMP!" echo ICVkIGJ5dGVzIChjb250ZW50IG1hdGNoZXM7IENSTEYgZml4ZWQgYXQgcnVudGltZSkiICUgKHJl
>> "!B64TMP!" echo bCwgbGVuKG9yaWcpKSkKICAgIGVsc2U6CiAgICAgICAgcHJpbnQoIiAgW0ZBSUxdICUtMzJzIDog
>> "!B64TMP!" echo aGVyZWRvYyAlZCB2cyBvcmlnICVkIChMRi1ub3JtYWxpc2VkKSIgJSAocmVsLCBsZW4oYSksIGxl
>> "!B64TMP!" echo bihiKSkpCiAgICAgICAgZm9yIGsgaW4gcmFuZ2UobWluKGxlbihhKSwgbGVuKGIpKSk6CiAgICAg
>> "!B64TMP!" echo ICAgICAgIGlmIGFba10gIT0gYltrXToKICAgICAgICAgICAgICAgIHByaW50KCIgICAgZmlyc3Qg
>> "!B64TMP!" echo ZGlmZiBhdCBieXRlICVkOiBoZXJlZG9jPSVyIG9yaWc9JXIiICUgKGssIGFbazprKzMwXSwgYltr
>> "!B64TMP!" echo OmsrMzBdKSkKICAgICAgICAgICAgICAgIGJyZWFrCiAgICAgICAgb2sgPSBGYWxzZQoKcHJpbnQo
>> "!B64TMP!" echo KQpwcmludCgiQUxMIEdPT0QiIGlmIG9rIGVsc2UgIkZBSUxVUkVTIikK
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
>> "!B64TMP!" echo bGRlciwgdGhlIH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaAojICAgICBza2lsbCBp
>> "!B64TMP!" echo bnN0YWxsLCB0aGUgaW5zdGFsbC1kaXIudHh0IGhpbnQsIGFuZCB0aGUgdW5pbnN0YWxsZXIuCiMg
>> "!B64TMP!" echo ICAqIENPUkUtTU9ERSB0ZXN0OiB0aGUgZGVmYXVsdCAobm8gRmlyZWNyYXdsIGFjY291bnQpIGlu
>> "!B64TMP!" echo c3RhbGwgbXVzdCBza2lwCiMgICAgIHRoZSAxOSBhY2NvdW50LWdhdGVkIHRvb2wgc2NyaXB0cyBh
>> "!B64TMP!" echo bmQgaW5zdGFsbCB0aGUgY29yZS1vbmx5IFNLSUxMLm1kLgojICAgKiBBQ0NPVU5ULU1PREUgdGVz
>> "!B64TMP!" echo dDogcmUtcnVucyB0aGUgaW5zdGFsbGVyIHdpdGggYSBmYWtlIEZpcmVjcmF3bCBhY2NvdW50CiMg
>> "!B64TMP!" echo ICAgIGFuZCB2ZXJpZmllcyBhbGwgMjQgdG9vbHMgaW5zdGFsbCwgdGhlIGNyZWRlbnRpYWxzIGxh
>> "!B64TMP!" echo bmQgaW4gLmVudiwgYW5kCiMgICAgIGZpcmVjcmF3bF9hcGkucHkgcGlja3MgdGhlbSB1cCAocm91
>> "!B64TMP!" echo dGluZyB0aGUgdG9vbHMgdG8gdGhlIGNsb3VkIEFQSSkuCiMgICAqIFNFTEYtSEVBTCB0ZXN0OiBm
>> "!B64TMP!" echo YWtlIFNlYXJYTkcvRmlyZWNyYXdsIEhUVFAgc2VydmVycyArIGEgbW9jawojICAgICBgZG9ja2Vy
>> "!B64TMP!" echo IGNvbXBvc2UgdXBgIHRoYXQgc3RhcnRzIHRoZW0sIHZlcmlmeWluZyB0aGF0IHdlYl9zZWFyY2gu
>> "!B64TMP!" echo cHkgLwojICAgICB3ZWJfc2NyYXBlLnB5IGF1dG8tc3RhcnQgYSBkb3duIHN0YWNrIGFuZCByZXRy
>> "!B64TMP!" echo eSAoYW5kIHJlcG9ydCBjbGVhbmx5CiMgICAgIHdoZW4gdGhlIHN0YWNrIGNhbm5vdCBjb21lIHVw
>> "!B64TMP!" echo KS4KIyAgICogRE9DS0VSIEFVVE8tU1RBUlQgdGVzdDogYSBtb2NrIGRvY2tlciB3aG9zZSBlbmdp
>> "!B64TMP!" echo bmUgaXMgRE9XTiArIGEgbW9jawojICAgICBzeXN0ZW1jdGwgdGhhdCBzdGFydHMgaXQsIHZlcmlm
>> "!B64TMP!" echo eWluZyB0aGUgaW5zdGFsbGVyIGxhdW5jaGVzIHRoZSBlbmdpbmUKIyAgICAgaXRzZWxmLCB3YWl0
>> "!B64TMP!" echo cyBmb3IgaXQsIGFuZCBjb21wbGV0ZXMgKHBsdXMgYm90aCBmYWlsdXJlIHBhdGhzKS4KIyBBbnkg
>> "!B64TMP!" echo cHJlLWV4aXN0aW5nIH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaCBpcyBiYWNrZWQg
>> "!B64TMP!" echo dXAgYW5kIHJlc3RvcmVkLgpzZXQgLXUKClJPT1Q9IiQoY2QgIiQoZGlybmFtZSAiJDAiKSIgJiYg
>> "!B64TMP!" echo cHdkKSIKSU5TVEFMTEVSPSIkUk9PVC9sb2NhbC1zZWFyY2gvaW5zdGFsbC1sb2NhbC1zZWFyY2gu
>> "!B64TMP!" echo c2giClRFU1RST09UPSIkUk9PVC8ubHMtdGVzdC0kJCIKU1JDX0RJUj0iJFRFU1RST09UL3NyYy1v
>> "!B64TMP!" echo bmx5LWluc3RhbGxlciIKVEdUX0RJUj0iJFRFU1RST09UL3RhcmdldCIKTU9DS0JJTj0iJFRFU1RS
>> "!B64TMP!" echo T09UL2JpbiIKU0tJTExfRElSPSIkSE9NRS8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo IgpTS0lMTF9CQUs9IiIKClBZPSIkKGNvbW1hbmQgLXYgcHl0aG9uMyB8fCBjb21tYW5kIC12IHB5
>> "!B64TMP!" echo dGhvbikiCmlmIFsgLXogIiRQWSIgXTsgdGhlbgogIGVjaG8gIltFUlJPUl0gcHl0aG9uMy9weXRo
>> "!B64TMP!" echo b24gaXMgcmVxdWlyZWQgZm9yIHRoaXMgdGVzdC4iID4mMgogIGV4aXQgMQpmaQoKY2xlYW51cCgp
>> "!B64TMP!" echo IHsKICByYz0kPwogICMga2lsbCB0aGUgZmFrZSBzdGFjayBzZXJ2ZXIgaWYgYSBzZWxmLWhlYWwg
>> "!B64TMP!" echo cGhhc2UgbGVmdCBpdCBydW5uaW5nCiAgaWYgWyAtZiAiJFRFU1RST09UL2Zha2Vfc3RhY2sucGlk
>> "!B64TMP!" echo IiBdOyB0aGVuCiAgICBraWxsICIkKGNhdCAiJFRFU1RST09UL2Zha2Vfc3RhY2sucGlkIiAyPi9k
>> "!B64TMP!" echo ZXYvbnVsbCkiIDI+L2Rldi9udWxsCiAgICBybSAtZiAiJFRFU1RST09UL2Zha2Vfc3RhY2sucGlk
>> "!B64TMP!" echo IgogIGZpCiAgcm0gLXJmICIkU0tJTExfRElSIiAyPi9kZXYvbnVsbAogIGlmIFsgLW4gIiRTS0lM
>> "!B64TMP!" echo TF9CQUsiIF0gJiYgWyAtZCAiJFNLSUxMX0JBSyIgXTsgdGhlbgogICAgbXYgIiRTS0lMTF9CQUsi
>> "!B64TMP!" echo ICIkU0tJTExfRElSIiAyPi9kZXYvbnVsbAogIGZpCiAgaWYgWyAiJHJjIiA9IDAgXTsgdGhlbiBy
>> "!B64TMP!" echo bSAtcmYgIiRURVNUUk9PVCI7IGZpCn0KdHJhcCBjbGVhbnVwIEVYSVQKCm1rZGlyIC1wICIkU1JD
>> "!B64TMP!" echo X0RJUiIgIiRUR1RfRElSIiAiJE1PQ0tCSU4iCgojIEJhY2sgdXAgYW55IHJlYWwgc2tpbGwgaW5z
>> "!B64TMP!" echo dGFsbCBzbyB0aGUgdGVzdCBjYW4gbmV2ZXIgZGVzdHJveSBpdC4KaWYgWyAtZCAiJFNLSUxMX0RJ
>> "!B64TMP!" echo UiIgXTsgdGhlbgogIFNLSUxMX0JBSz0iJFRFU1RST09UL3NraWxsLWJhY2t1cCIKICBtdiAiJFNL
>> "!B64TMP!" echo SUxMX0RJUiIgIiRTS0lMTF9CQUsiCmZpCgojIC0tLSBtb2NrIGRvY2tlciArIGRvY2tlciBjb21w
>> "!B64TMP!" echo b3NlIHNvIHRoZSBpbnN0YWxsZXIncyBjaGVja3MgcGFzcyAtLS0tLS0tLS0tLQpjYXQgPiAiJE1P
>> "!B64TMP!" echo Q0tCSU4vZG9ja2VyIiA8PCdNT0NLJwojIS91c3IvYmluL2VudiBiYXNoCmNhc2UgIiQxIiBpbgog
>> "!B64TMP!" echo IGluZm8pICAgICAgICBleGl0IDAgOzsKICBjb21wb3NlKQogICAgY2FzZSAiJDIiIGluCiAgICAg
>> "!B64TMP!" echo IHZlcnNpb24pIGVjaG8gIkRvY2tlciBDb21wb3NlIHZlcnNpb24gdjIuMC4wLXRlc3QiOyBleGl0
>> "!B64TMP!" echo IDAgOzsKICAgICAgcHVsbCkgICAgZWNobyAiW21vY2tdIHB1bGwgb2siOyAgIGV4aXQgMCA7Owog
>> "!B64TMP!" echo ICAgICB1cCkgICAgICBlY2hvICJbbW9ja10gdXAgb2siOyAgICAgZXhpdCAwIDs7CiAgICAgIGRv
>> "!B64TMP!" echo d24pICAgIGVjaG8gIlttb2NrXSBkb3duIG9rIjsgICBleGl0IDAgOzsKICAgICAgKikgICAgICAg
>> "!B64TMP!" echo ZWNobyAiW21vY2tdIGRvY2tlciBjb21wb3NlICQqIjsgZXhpdCAwIDs7CiAgICBlc2FjIDs7CiAg
>> "!B64TMP!" echo KikgZWNobyAiW21vY2tdIGRvY2tlciAkKiI7IGV4aXQgMCA7Owplc2FjCk1PQ0sKY2htb2QgK3gg
>> "!B64TMP!" echo IiRNT0NLQklOL2RvY2tlciIKZXhwb3J0IFBBVEg9IiRNT0NLQklOOiRQQVRIIgoKIyAtLS0gY29w
>> "!B64TMP!" echo eSBPTkxZIHRoZSBpbnN0YWxsZXIgLnNoIGludG8gdGhlIHNvdXJjZSBmb2xkZXIgLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLQpjcCAiJElOU1RBTExFUiIgIiRTUkNfRElSLyIKY2htb2QgK3ggIiRTUkNfRElS
>> "!B64TMP!" echo L2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoIgoKZWNobyAiU291cmNlIGZvbGRlciBjb250ZW50cyAo
>> "!B64TMP!" echo c2hvdWxkIGJlIE9OTFkgaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gpOiIKbHMgLWxhICIkU1JDX0RJ
>> "!B64TMP!" echo UiIKZWNobwoKIyAtLS0gcnVuIHRoZSBpbnN0YWxsZXIgd2l0aCBzY3JpcHRlZCBhbnN3ZXJzIChD
>> "!B64TMP!" echo T1JFIE1PREU6IG5vIGFjY291bnQpIC0tLS0tLS0tCiMgICBTdGVwIDE6IHRhcmdldCBmb2xkZXIs
>> "!B64TMP!" echo IFN0ZXAgMjogc2VhcnhuZyBwb3J0LCBTdGVwIDM6IGZpcmVjcmF3bCBwb3J0LAojICAgU3RlcCA0
>> "!B64TMP!" echo OiBjb25uZWN0IExMTT8gLT4gbiwgIFN0ZXAgNTogRmlyZWNyYXdsIGFjY291bnQ/IC0+IG4sICBj
>> "!B64TMP!" echo b25maXJtIC0+IHkKcHJpbnRmICclc1xuJXNcbiVzXG4lc1xuJXNcbiVzXG4nIFwKICAiJFRHVF9E
>> "!B64TMP!" echo SVIiIFwKICAiIiBcCiAgIiIgXAogICJuIiBcCiAgIm4iIFwKICAieSIgfCAiJFNSQ19ESVIvaW5z
>> "!B64TMP!" echo dGFsbC1sb2NhbC1zZWFyY2guc2giID4gIiRURVNUUk9PVC9pbnN0YWxsLmxvZyIgMj4mMQpSQz0k
>> "!B64TMP!" echo PwplY2hvICJJbnN0YWxsZXIgZXhpdCBjb2RlOiAkUkMiCmVjaG8gIi0tLS0tIGluc3RhbGwubG9n
>> "!B64TMP!" echo ICh0YWlsKSAtLS0tLSIKdGFpbCAtMzAgIiRURVNUUk9PVC9pbnN0YWxsLmxvZyIKZWNobyAiLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0iCgpQQVNTPTEKWyAiJFJDIiA9IDAgXSB8fCBQ
>> "!B64TMP!" echo QVNTPTAKCiMgLS0tIHZlcmlmeSB0aGUgdGFyZ2V0IGZvbGRlciBoYXMgZXZlcnl0aGluZyB3ZSBl
>> "!B64TMP!" echo eHBlY3QgLS0tLS0tLS0tLS0tLS0tLS0tLS0KZWNobwplY2hvICJUYXJnZXQgZm9sZGVyIGNvbnRl
>> "!B64TMP!" echo bnRzOiIKbHMgLWxhICIkVEdUX0RJUiIKZWNobwplY2hvICJUYXJnZXQgY29uZmlnL3NlYXJ4bmcg
>> "!B64TMP!" echo Y29udGVudHM6IgpscyAtbGEgIiRUR1RfRElSL2NvbmZpZy9zZWFyeG5nIgplY2hvCmVjaG8gIlRh
>> "!B64TMP!" echo cmdldCBsb2NhbC13ZWItc2VhcmNoIGNvbnRlbnRzOiIKZmluZCAiJFRHVF9ESVIvbG9jYWwtd2Vi
>> "!B64TMP!" echo LXNlYXJjaCIgLXR5cGUgZiB8IHNvcnQKCmNoZWNrKCkgewogIGlmIFsgLXMgIiRUR1RfRElSLyQx
>> "!B64TMP!" echo IiBdOyB0aGVuCiAgICBlY2hvICIgIFtPS10gICAkMSAgKCQod2MgLWMgPCAiJFRHVF9ESVIvJDEi
>> "!B64TMP!" echo KSBieXRlcykiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gJDEgIChtaXNzaW5nIG9yIGVtcHR5
>> "!B64TMP!" echo KSIKICAgIFBBU1M9MAogIGZpCn0KY2hlY2tfYWJzZW50KCkgewogIGlmIFsgLWUgIiRUR1RfRElS
>> "!B64TMP!" echo LyQxIiBdOyB0aGVuCiAgICBlY2hvICIgIFtGQUlMXSAkMSAgKG11c3QgTk9UIGJlIGluc3RhbGxl
>> "!B64TMP!" echo ZCB3aXRob3V0IGEgRmlyZWNyYXdsIGFjY291bnQpIgogICAgUEFTUz0wCiAgZWxzZQogICAgZWNo
>> "!B64TMP!" echo byAiICBbT0tdICAgJDEgIChhYnNlbnQgLSBjb3JlLW9ubHkgaW5zdGFsbCwgYXMgZXhwZWN0ZWQp
>> "!B64TMP!" echo IgogIGZpCn0KZWNobwplY2hvICJDaGVja2luZyBleHBlY3RlZCBmaWxlczoiCmNoZWNrICJkb2Nr
>> "!B64TMP!" echo ZXItY29tcG9zZS55bWwiCmNoZWNrICIuZW52LmV4YW1wbGUiCmNoZWNrICIuZW52IgpjaGVjayAi
>> "!B64TMP!" echo UkVBRE1FLm1kIgpjaGVjayAiTElDRU5TRSIKY2hlY2sgIi5naXRpZ25vcmUiCmNoZWNrICIuZ2l0
>> "!B64TMP!" echo YXR0cmlidXRlcyIKY2hlY2sgImNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbCIKY2hlY2sgIlJ1
>> "!B64TMP!" echo bi5iYXQiCmNoZWNrICJTdG9wLmJhdCIKY2hlY2sgIlVwZGF0ZS5iYXQiCmNoZWNrICJVbmluc3Rh
>> "!B64TMP!" echo bGwuYmF0IgpjaGVjayAicnVuLnNoIgpjaGVjayAic3RvcC5zaCIKY2hlY2sgInVwZGF0ZS5zaCIK
>> "!B64TMP!" echo Y2hlY2sgInVuaW5zdGFsbC5zaCIKY2hlY2sgImxvY2FsLXdlYi1zZWFyY2gvU0tJTEwubWQiCmNo
>> "!B64TMP!" echo ZWNrICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvY29uZmlnLnB5IgpjaGVjayAibG9jYWwtd2Vi
>> "!B64TMP!" echo LXNlYXJjaC9zY3JpcHRzL2Vuc3VyZV9zdGFjay5weSIKY2hlY2sgImxvY2FsLXdlYi1zZWFyY2gv
>> "!B64TMP!" echo c2NyaXB0cy9maXJlY3Jhd2xfYXBpLnB5IgpjaGVjayAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9zZWFyY2gucHkiCmNoZWNrICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3NjcmFw
>> "!B64TMP!" echo ZS5weSIKY2hlY2sgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbWFwLnB5IgpjaGVjayAi
>> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9jcmF3bC5weSIKY2hlY2sgImxvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gvc2NyaXB0cy93ZWJfY3Jhd2xfc3RhdHVzLnB5IgpjaGVjayAiaW5zdGFsbC1sb2NhbC1z
>> "!B64TMP!" echo ZWFyY2guYmF0IgpjaGVjayAiaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giCgojIC0tLSBjb3JlLW9u
>> "!B64TMP!" echo bHkgbW9kZTogdGhlIDE5IGFjY291bnQtZ2F0ZWQgc2NyaXB0cyBtdXN0IE5PVCBiZSBpbnN0YWxs
>> "!B64TMP!" echo ZWQgLS0tLS0tCmVjaG8KZWNobyAiQ2hlY2tpbmcgdGhlIGFjY291bnQtZ2F0ZWQgdG9vbHMgYXJl
>> "!B64TMP!" echo IE5PVCBpbnN0YWxsZWQgKG5vIEZpcmVjcmF3bCBhY2NvdW50KToiCmZvciBmIGluIHdlYl9hZ2Vu
>> "!B64TMP!" echo dC5weSB3ZWJfYWdlbnRfc3RhdHVzLnB5IHdlYl9pbnRlcmFjdC5weSB3ZWJfaW50ZXJhY3Rfc3Rv
>> "!B64TMP!" echo cC5weSBcCiAgICAgICAgIHdlYl9wYXJzZS5weSB3ZWJfbW9uaXRvcl9jcmVhdGUucHkgd2ViX21v
>> "!B64TMP!" echo bml0b3JfbGlzdC5weSBcCiAgICAgICAgIHdlYl9tb25pdG9yX2dldC5weSB3ZWJfbW9uaXRvcl91
>> "!B64TMP!" echo cGRhdGUucHkgd2ViX21vbml0b3JfZGVsZXRlLnB5IFwKICAgICAgICAgd2ViX21vbml0b3JfcnVu
>> "!B64TMP!" echo LnB5IHdlYl9tb25pdG9yX2NoZWNrcy5weSB3ZWJfbW9uaXRvcl9jaGVjay5weSBcCiAgICAgICAg
>> "!B64TMP!" echo IHdlYl9yZXNlYXJjaF9zZWFyY2gucHkgd2ViX3Jlc2VhcmNoX2luc3BlY3QucHkgd2ViX3Jlc2Vh
>> "!B64TMP!" echo cmNoX3JlbGF0ZWQucHkgXAogICAgICAgICB3ZWJfcmVzZWFyY2hfcmVhZC5weSB3ZWJfZ2l0aHVi
>> "!B64TMP!" echo X3NlYXJjaC5weSB3ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weTsgZG8KICBjaGVja19hYnNlbnQgImxv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2gvc2NyaXB0cy8kZiIKZG9uZQpjaGVja19hYnNlbnQgImxvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gvU0tJTEwtY29yZS5tZCIKCiMgU0tJTEwubWQgbXVzdCBiZSB0aGUgY29yZS1vbmx5IHZh
>> "!B64TMP!" echo cmlhbnQgKG5vIGFjY291bnQgdG9vbHMgbWVudGlvbmVkKQppZiBncmVwIC1xICI1IHRvb2xzOiBz
>> "!B64TMP!" echo ZWFyY2gsIHNjcmFwZSwgbWFwLCBjcmF3bCwgY3Jhd2wgc3RhdHVzIiAiJFRHVF9ESVIvbG9jYWwt
>> "!B64TMP!" echo d2ViLXNlYXJjaC9TS0lMTC5tZCIgXAogICAmJiAhIGdyZXAgLXEgIndlYl9tb25pdG9yX2NyZWF0
>> "!B64TMP!" echo ZSIgIiRUR1RfRElSL2xvY2FsLXdlYi1zZWFyY2gvU0tJTEwubWQiIFwKICAgJiYgISBncmVwIC1x
>> "!B64TMP!" echo ICJ3ZWJfZGV2ZWxvcGVyX3NlYXJjaCIgIiRUR1RfRElSL2xvY2FsLXdlYi1zZWFyY2gvU0tJTEwu
>> "!B64TMP!" echo bWQiOyB0aGVuCiAgZWNobyAiICBbT0tdICAgbG9jYWwtd2ViLXNlYXJjaC9TS0lMTC5tZCBpcyB0
>> "!B64TMP!" echo aGUgY29yZS1vbmx5IHZhcmlhbnQiCmVsc2UKICBlY2hvICIgIFtGQUlMXSBsb2NhbC13ZWItc2Vh
>> "!B64TMP!" echo cmNoL1NLSUxMLm1kIGlzIG5vdCB0aGUgY29yZS1vbmx5IHZhcmlhbnQiCiAgUEFTUz0wCmZpCgoj
>> "!B64TMP!" echo IHZlcmlmeSAuZW52IGhhcyB0aGUgY2hvc2VuIHBvcnRzICsgYSByZWFsIHNlY3JldAplY2hvCmVj
>> "!B64TMP!" echo aG8gIi0tLS0tIC5lbnYgY29udGVudHMgLS0tLS0iCmNhdCAiJFRHVF9ESVIvLmVudiIKZWNobyAi
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSIKCmlmIGdyZXAgLXEgIl5TRUFSWE5HX1BPUlQ9OTk5
>> "!B64TMP!" echo MCQiICIkVEdUX0RJUi8uZW52IiBcCiAgICYmIGdyZXAgLXEgIl5GSVJFQ1JBV0xfUE9SVD05OTkx
>> "!B64TMP!" echo JCIgIiRUR1RfRElSLy5lbnYiIFwKICAgJiYgZ3JlcCAtcSAiXlNFQVJYTkdfU0VDUkVUPVswLTlh
>> "!B64TMP!" echo LWZdXHs2NFx9JCIgIiRUR1RfRElSLy5lbnYiOyB0aGVuCiAgZWNobyAiW09LXSAuZW52IGhhcyBj
>> "!B64TMP!" echo b3JyZWN0IHBvcnRzIGFuZCBhIDY0LWhleCBzZWNyZXQiCmVsc2UKICBlY2hvICJbRkFJTF0gLmVu
>> "!B64TMP!" echo diBpcyBtYWxmb3JtZWQiCiAgUEFTUz0wCmZpCgojIGNvcmUgbW9kZTogbm8gRmlyZWNyYXdsIGFj
>> "!B64TMP!" echo Y291bnQgY3JlZGVudGlhbHMgaW4gLmVudgppZiBncmVwIC1xICJeRklSRUNSQVdMX0FQSV9LRVk9
>> "!B64TMP!" echo IiAiJFRHVF9ESVIvLmVudiIgXAogICB8fCBncmVwIC1xICJeRklSRUNSQVdMX0FQSV9VUkw9IiAi
>> "!B64TMP!" echo JFRHVF9ESVIvLmVudiI7IHRoZW4KICBlY2hvICJbRkFJTF0gLmVudiBzaG91bGQgbm90IGNvbnRh
>> "!B64TMP!" echo aW4gRmlyZWNyYXdsIGFjY291bnQgY3JlZGVudGlhbHMgKGNvcmUgbW9kZSkiCiAgUEFTUz0wCmVs
>> "!B64TMP!" echo c2UKICBlY2hvICJbT0tdIC5lbnYgaGFzIG5vIEZpcmVjcmF3bCBhY2NvdW50IGNyZWRlbnRpYWxz
>> "!B64TMP!" echo IChjb3JlIG1vZGUpIgpmaQoKIyB2ZXJpZnkgdGhlIHNlY3JldCBnb3QgaW5qZWN0ZWQgaW50byBz
>> "!B64TMP!" echo ZXR0aW5ncy55bWwgKG5vIHBsYWNlaG9sZGVyIGxlZnQpCmlmIGdyZXAgLXEgIl9fU0VBUlhOR19T
>> "!B64TMP!" echo RUNSRVRfUExBQ0VIT0xERVJfXyIgIiRUR1RfRElSL2NvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnlt
>> "!B64TMP!" echo bCI7IHRoZW4KICBlY2hvICJbRkFJTF0gc2V0dGluZ3MueW1sIHN0aWxsIGhhcyB0aGUgcGxhY2Vo
>> "!B64TMP!" echo b2xkZXIgKGluamVjdGlvbiBmYWlsZWQpIgogIFBBU1M9MAplbHNlCiAgZWNobyAiW09LXSBzZXR0
>> "!B64TMP!" echo aW5ncy55bWwgbm8gbG9uZ2VyIGhhcyB0aGUgcGxhY2Vob2xkZXIgKHNlY3JldCBpbmplY3RlZCki
>> "!B64TMP!" echo CmZpCgojIHZlcmlmeSAuYmF0IGZpbGVzIGhhdmUgQ1JMRiBsaW5lIGVuZGluZ3MKQkFUX0hBU19D
>> "!B64TMP!" echo UkxGPTEKZm9yIGYgaW4gUnVuLmJhdCBTdG9wLmJhdCBVcGRhdGUuYmF0IFVuaW5zdGFsbC5iYXQg
>> "!B64TMP!" echo aW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0OyBkbwogIGlmICEgZ3JlcCAtcSAkJ1xyJyAiJFRHVF9E
>> "!B64TMP!" echo SVIvJGYiIDI+L2Rldi9udWxsOyB0aGVuCiAgICBlY2hvICJbRkFJTF0gJGYgZG9lcyBub3QgaGF2
>> "!B64TMP!" echo ZSBDUkxGIGxpbmUgZW5kaW5ncyIKICAgIEJBVF9IQVNfQ1JMRj0wCiAgZmkKZG9uZQpbICIkQkFU
>> "!B64TMP!" echo X0hBU19DUkxGIiA9IDEgXSAmJiBlY2hvICJbT0tdIGFsbCAuYmF0IGZpbGVzIGhhdmUgQ1JMRiBs
>> "!B64TMP!" echo aW5lIGVuZGluZ3MiCgojIC0tLSB2ZXJpZnkgdGhlIHNraWxsIHdhcyBpbnN0YWxsZWQgaW50byB+
>> "!B64TMP!" echo Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2ggLS0tLS0tLS0KZWNobwplY2hvICJTa2ls
>> "!B64TMP!" echo bCBkaXIgY29udGVudHMgKCRTS0lMTF9ESVIpOiIKZmluZCAiJFNLSUxMX0RJUiIgLXR5cGUgZiAy
>> "!B64TMP!" echo Pi9kZXYvbnVsbCB8IHNvcnQKClNLSUxMX0ZJTEVTPSJTS0lMTC5tZCBzY3JpcHRzL2NvbmZpZy5w
>> "!B64TMP!" echo eSBzY3JpcHRzL2Vuc3VyZV9zdGFjay5weSBzY3JpcHRzL2ZpcmVjcmF3bF9hcGkucHkgXAogICAg
>> "!B64TMP!" echo ICAgICBzY3JpcHRzL3dlYl9zZWFyY2gucHkgc2NyaXB0cy93ZWJfc2NyYXBlLnB5IHNjcmlwdHMv
>> "!B64TMP!" echo d2ViX21hcC5weSBcCiAgICAgICAgIHNjcmlwdHMvd2ViX2NyYXdsLnB5IHNjcmlwdHMvd2ViX2Ny
>> "!B64TMP!" echo YXdsX3N0YXR1cy5weSIKCmZvciBmIGluICRTS0lMTF9GSUxFUzsgZG8KICBpZiBbIC1zICIkU0tJ
>> "!B64TMP!" echo TExfRElSLyRmIiBdOyB0aGVuCiAgICBlY2hvICIgIFtPS10gICBza2lsbDogJGYiCiAgZWxzZQog
>> "!B64TMP!" echo ICAgZWNobyAiICBbRkFJTF0gc2tpbGw6ICRmIChtaXNzaW5nIG9yIGVtcHR5KSIKICAgIFBBU1M9
>> "!B64TMP!" echo MAogIGZpCmRvbmUKCiMgY29yZSBtb2RlOiB0aGUgYWNjb3VudC1nYXRlZCBzY3JpcHRzIG11c3Qg
>> "!B64TMP!" echo YmUgYWJzZW50IGZyb20gdGhlIHNraWxsIGRpciB0b28KU0tJTExfQUJTRU5UPSJzY3JpcHRzL3dl
>> "!B64TMP!" echo Yl9hZ2VudC5weSBzY3JpcHRzL3dlYl9hZ2VudF9zdGF0dXMucHkgc2NyaXB0cy93ZWJfaW50ZXJh
>> "!B64TMP!" echo Y3QucHkgXAogICAgICAgICBzY3JpcHRzL3dlYl9pbnRlcmFjdF9zdG9wLnB5IHNjcmlwdHMvd2Vi
>> "!B64TMP!" echo X3BhcnNlLnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfbW9uaXRvcl9jcmVhdGUucHkgc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfbW9uaXRvcl9saXN0LnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfbW9uaXRvcl9nZXQu
>> "!B64TMP!" echo cHkgc2NyaXB0cy93ZWJfbW9uaXRvcl91cGRhdGUucHkgXAogICAgICAgICBzY3JpcHRzL3dlYl9t
>> "!B64TMP!" echo b25pdG9yX2RlbGV0ZS5weSBzY3JpcHRzL3dlYl9tb25pdG9yX3J1bi5weSBcCiAgICAgICAgIHNj
>> "!B64TMP!" echo cmlwdHMvd2ViX21vbml0b3JfY2hlY2tzLnB5IHNjcmlwdHMvd2ViX21vbml0b3JfY2hlY2sucHkg
>> "!B64TMP!" echo XAogICAgICAgICBzY3JpcHRzL3dlYl9yZXNlYXJjaF9zZWFyY2gucHkgc2NyaXB0cy93ZWJfcmVz
>> "!B64TMP!" echo ZWFyY2hfaW5zcGVjdC5weSBcCiAgICAgICAgIHNjcmlwdHMvd2ViX3Jlc2VhcmNoX3JlbGF0ZWQu
>> "!B64TMP!" echo cHkgc2NyaXB0cy93ZWJfcmVzZWFyY2hfcmVhZC5weSBcCiAgICAgICAgIHNjcmlwdHMvd2ViX2dp
>> "!B64TMP!" echo dGh1Yl9zZWFyY2gucHkgc2NyaXB0cy93ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSIKZm9yIGYgaW4g
>> "!B64TMP!" echo JFNLSUxMX0FCU0VOVDsgZG8KICBpZiBbIC1lICIkU0tJTExfRElSLyRmIiBdOyB0aGVuCiAgICBl
>> "!B64TMP!" echo Y2hvICIgIFtGQUlMXSBza2lsbDogJGYgKG11c3QgTk9UIGJlIGluc3RhbGxlZCB3aXRob3V0IGEg
>> "!B64TMP!" echo RmlyZWNyYXdsIGFjY291bnQpIgogICAgUEFTUz0wCiAgZWxzZQogICAgZWNobyAiICBbT0tdICAg
>> "!B64TMP!" echo c2tpbGw6ICRmIChhYnNlbnQgLSBjb3JlLW9ubHkgc2tpbGwsIGFzIGV4cGVjdGVkKSIKICBmaQpk
>> "!B64TMP!" echo b25lCmlmIFsgLWUgIiRTS0lMTF9ESVIvU0tJTEwtY29yZS5tZCIgXTsgdGhlbgogIGVjaG8gIiAg
>> "!B64TMP!" echo W0ZBSUxdIHNraWxsOiBTS0lMTC1jb3JlLm1kIGxlYWtlZCBpbnRvIHRoZSBpbnN0YWxsZWQgc2tp
>> "!B64TMP!" echo bGwiCiAgUEFTUz0wCmVsc2UKICBlY2hvICIgIFtPS10gICBza2lsbDogU0tJTEwtY29yZS5tZCBu
>> "!B64TMP!" echo b3QgcHJlc2VudCAoYXMgZXhwZWN0ZWQpIgpmaQoKIyB2ZXJpZnkgdGhlIHNraWxsIGZpbGVzIGFy
>> "!B64TMP!" echo ZSBpZGVudGljYWwgdG8gdGhlIHRhcmdldCdzIGxvY2FsLXdlYi1zZWFyY2ggY29waWVzCmZvciBm
>> "!B64TMP!" echo IGluICRTS0lMTF9GSUxFUzsgZG8KICBpZiBjbXAgLXMgIiRTS0lMTF9ESVIvJGYiICIkVEdUX0RJ
>> "!B64TMP!" echo Ui9sb2NhbC13ZWItc2VhcmNoLyRmIjsgdGhlbgogICAgZWNobyAiICBbT0tdICAgc2tpbGwgZmls
>> "!B64TMP!" echo ZSBtYXRjaGVzIGJ1bmRsZWQgY29weTogJGYiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gc2tp
>> "!B64TMP!" echo bGwgZmlsZSBkaWZmZXJzIGZyb20gYnVuZGxlZCBjb3B5OiAkZiIKICAgIFBBU1M9MAogIGZpCmRv
>> "!B64TMP!" echo bmUKCiMgdmVyaWZ5IHRoZSBpbnN0YWxsLWRpci50eHQgaGludCAoYm90aCBjb3BpZXMpIHBvaW50
>> "!B64TMP!" echo cyBhdCB0aGUgdGFyZ2V0CmlmIFsgIiQoY2F0ICIkU0tJTExfRElSL2luc3RhbGwtZGlyLnR4dCIg
>> "!B64TMP!" echo Mj4vZGV2L251bGwpIiA9ICIkVEdUX0RJUiIgXTsgdGhlbgogIGVjaG8gIiAgW09LXSAgIHNraWxs
>> "!B64TMP!" echo IGluc3RhbGwtZGlyLnR4dCAtPiAkVEdUX0RJUiIKZWxzZQogIGVjaG8gIiAgW0ZBSUxdIHNraWxs
>> "!B64TMP!" echo IGluc3RhbGwtZGlyLnR4dCBpcyB3cm9uZzogJChjYXQgIiRTS0lMTF9ESVIvaW5zdGFsbC1kaXIu
>> "!B64TMP!" echo dHh0IiAyPi9kZXYvbnVsbCkiCiAgUEFTUz0wCmZpCmlmIFsgIiQoY2F0ICIkVEdUX0RJUi9sb2Nh
>> "!B64TMP!" echo bC13ZWItc2VhcmNoL2luc3RhbGwtZGlyLnR4dCIgMj4vZGV2L251bGwpIiA9ICIkVEdUX0RJUiIg
>> "!B64TMP!" echo XTsgdGhlbgogIGVjaG8gIiAgW09LXSAgIGJ1bmRsZWQgaW5zdGFsbC1kaXIudHh0IC0+ICRUR1Rf
>> "!B64TMP!" echo RElSIgplbHNlCiAgZWNobyAiICBbRkFJTF0gYnVuZGxlZCBpbnN0YWxsLWRpci50eHQgaXMgd3Jv
>> "!B64TMP!" echo bmc6ICQoY2F0ICIkVEdUX0RJUi9sb2NhbC13ZWItc2VhcmNoL2luc3RhbGwtZGlyLnR4dCIgMj4v
>> "!B64TMP!" echo ZGV2L251bGwpIgogIFBBU1M9MApmaQoKIyAtLS0gdmVyaWZ5IHRoZSBoaW50IGFjdHVhbGx5IHdv
>> "!B64TMP!" echo cmtzOiBydW4gY29uZmlnLnB5J3MgZmluZGVyIHN0YW5kYWxvbmUgLS0tLS0tCiIkUFkiIC0gIiRU
>> "!B64TMP!" echo R1RfRElSIiA8PCdQWUVPRicKaW1wb3J0IHN5cywgb3MKZXhwZWN0ZWQgPSBzeXMuYXJndlsxXQoj
>> "!B64TMP!" echo IFNpbXVsYXRlIHRoZSBza2lsbCBiZWluZyBydW4gZnJvbSB+Ly5hZ2VudHMvc2tpbGxzL2xvY2Fs
>> "!B64TMP!" echo LXdlYi1zZWFyY2gvc2NyaXB0cwpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5leHBhbmR1c2Vy
>> "!B64TMP!" echo KCJ+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cyIpKQpvcy5lbnZpcm9u
>> "!B64TMP!" echo LnBvcCgiTE9DQUxfU0VBUkNIX0RJUiIsIE5vbmUpCmltcG9ydCBjb25maWcKZm91bmQgPSBjb25m
>> "!B64TMP!" echo aWcuZmluZF9pbnN0YWxsX2RpcigpCmlmIGZvdW5kID09IGV4cGVjdGVkOgogICAgcHJpbnQoIiAg
>> "!B64TMP!" echo W09LXSAgIGNvbmZpZy5maW5kX2luc3RhbGxfZGlyKCkgLT4gJXMgKGhpbnQgd29ya3MpIiAlIGZv
>> "!B64TMP!" echo dW5kKQplbHNlOgogICAgcHJpbnQoIiAgW0ZBSUxdIGNvbmZpZy5maW5kX2luc3RhbGxfZGlyKCkg
>> "!B64TMP!" echo LT4gJXIgKGV4cGVjdGVkICVyKSIgJSAoZm91bmQsIGV4cGVjdGVkKSkKICAgIHN5cy5leGl0KDEp
>> "!B64TMP!" echo CmVwcyA9IGNvbmZpZy5lbmRwb2ludHMoZm91bmQpCmlmIGVwcyA9PSB7InNlYXJ4bmciOiAiaHR0
>> "!B64TMP!" echo cDovL2xvY2FsaG9zdDo5OTkwIiwgImZpcmVjcmF3bCI6ICJodHRwOi8vbG9jYWxob3N0Ojk5OTEi
>> "!B64TMP!" echo fToKICAgIHByaW50KCIgIFtPS10gICBlbmRwb2ludHMgcmVhZCBmcm9tIC5lbnY6ICVzIiAlIGVw
>> "!B64TMP!" echo cykKZWxzZToKICAgIHByaW50KCIgIFtGQUlMXSBlbmRwb2ludHMgd3Jvbmc6ICVzIiAlIGVwcykK
>> "!B64TMP!" echo ICAgIHN5cy5leGl0KDEpClBZRU9GClsgJD8gPSAwIF0gfHwgUEFTUz0wCgojIC0tLSB2ZXJpZnkg
>> "!B64TMP!" echo d2ViX3NlYXJjaC5weSAvIHdlYl9zY3JhcGUucHkgcmVzb2x2ZSB0aGUgZW5kcG9pbnRzIC0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0KIiRQWSIgLSA8PCdQWUVPRicKaW1wb3J0IHN5cywgb3MKc3lzLnBhdGguaW5zZXJ0
>> "!B64TMP!" echo KDAsIG9zLnBhdGguZXhwYW5kdXNlcigifi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo L3NjcmlwdHMiKSkKaW1wb3J0IHdlYl9zZWFyY2gKaWYgd2ViX3NlYXJjaC5CQVNFLmVuZHN3aXRo
>> "!B64TMP!" echo KCI6OTk5MC9zZWFyY2giKToKICAgIHByaW50KCIgIFtPS10gICB3ZWJfc2VhcmNoLkJBU0UgPSAl
>> "!B64TMP!" echo cyIgJSB3ZWJfc2VhcmNoLkJBU0UpCmVsc2U6CiAgICBwcmludCgiICBbRkFJTF0gd2ViX3NlYXJj
>> "!B64TMP!" echo aC5CQVNFID0gJXMiICUgd2ViX3NlYXJjaC5CQVNFKQogICAgc3lzLmV4aXQoMSkKaW1wb3J0IHdl
>> "!B64TMP!" echo Yl9zY3JhcGUKaWYgd2ViX3NjcmFwZS5FTkRQT0lOVC5lbmRzd2l0aCgiOjk5OTEvdjEvc2NyYXBl
>> "!B64TMP!" echo Iik6CiAgICBwcmludCgiICBbT0tdICAgd2ViX3NjcmFwZS5FTkRQT0lOVCA9ICVzIiAlIHdlYl9z
>> "!B64TMP!" echo Y3JhcGUuRU5EUE9JTlQpCmVsc2U6CiAgICBwcmludCgiICBbRkFJTF0gd2ViX3NjcmFwZS5FTkRQ
>> "!B64TMP!" echo T0lOVCA9ICVzIiAlIHdlYl9zY3JhcGUuRU5EUE9JTlQpCiAgICBzeXMuZXhpdCgxKQpQWUVPRgpb
>> "!B64TMP!" echo ICQ/ID0gMCBdIHx8IFBBU1M9MAoKIyAtLS0gdmVyaWZ5IHRoZSBjb3JlIEZpcmVjcmF3bCB0b29s
>> "!B64TMP!" echo IHNjcmlwdHMgcmVzb2x2ZSB0aGUgTE9DQUwgZW5kcG9pbnRzIC0tLS0tLQoiJFBZIiAtIDw8J1BZ
>> "!B64TMP!" echo RU9GJwppbXBvcnQgc3lzLCBvcwpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5leHBhbmR1c2Vy
>> "!B64TMP!" echo KCJ+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cyIpKQppbXBvcnQgZmly
>> "!B64TMP!" echo ZWNyYXdsX2FwaSBhcyBmYwppZiBmYy5iYXNlX3VybCgpLmVuZHN3aXRoKCI6OTk5MSIpIGFuZCBm
>> "!B64TMP!" echo Yy5pc19sb2NhbCgpOgogICAgcHJpbnQoIiAgW09LXSAgIGZpcmVjcmF3bF9hcGkuYmFzZV91cmwg
>> "!B64TMP!" echo PSAlcyAobG9jYWwgc3RhY2spIiAlIGZjLmJhc2VfdXJsKCkpCmVsc2U6CiAgICBwcmludCgiICBb
>> "!B64TMP!" echo RkFJTF0gZmlyZWNyYXdsX2FwaS5iYXNlX3VybCA9ICVzIiAlIGZjLmJhc2VfdXJsKCkpCiAgICBz
>> "!B64TMP!" echo eXMuZXhpdCgxKQppZiBmYy5hdXRoX2hlYWRlcnMoKS5nZXQoIkF1dGhvcml6YXRpb24iKSBpcyBO
>> "!B64TMP!" echo b25lOgogICAgcHJpbnQoIiAgW09LXSAgIG5vIEJlYXJlciBrZXkgaW4gY29yZSBtb2RlIChsb2Nh
>> "!B64TMP!" echo bCBzdGFjaywgbm8gYWNjb3VudCkiKQplbHNlOgogICAgcHJpbnQoIiAgW0ZBSUxdIHVuZXhwZWN0
>> "!B64TMP!" echo ZWQgQXV0aG9yaXphdGlvbiBoZWFkZXIgaW4gY29yZSBtb2RlIikKICAgIHN5cy5leGl0KDEpCmNo
>> "!B64TMP!" echo ZWNrcyA9IFsKICAgICgid2ViX21hcCIsICAgICAgICAgICIvdjEvbWFwIiksCiAgICAoIndlYl9j
>> "!B64TMP!" echo cmF3bCIsICAgICAgICAiL3YxL2NyYXdsIiksCiAgICAoIndlYl9jcmF3bF9zdGF0dXMiLCAiL3Yx
>> "!B64TMP!" echo L2NyYXdsIiksCl0KZm9yIG5hbWUsIHN1ZmZpeCBpbiBjaGVja3M6CiAgICBtb2QgPSBfX2ltcG9y
>> "!B64TMP!" echo dF9fKG5hbWUpCiAgICBlbmRwb2ludCA9IG1vZC5FTkRQT0lOVAogICAgaWYgZW5kcG9pbnQuZW5k
>> "!B64TMP!" echo c3dpdGgoIjo5OTkxIiArIHN1ZmZpeCk6CiAgICAgICAgcHJpbnQoIiAgW09LXSAgICVzLkVORFBP
>> "!B64TMP!" echo SU5UID0gJXMiICUgKG5hbWUsIGVuZHBvaW50KSkKICAgIGVsc2U6CiAgICAgICAgcHJpbnQoIiAg
>> "!B64TMP!" echo W0ZBSUxdICVzLkVORFBPSU5UID0gJXMgKGV4cGVjdGVkIHN1ZmZpeCAlcykiICUgKG5hbWUsIGVu
>> "!B64TMP!" echo ZHBvaW50LCBzdWZmaXgpKQogICAgICAgIHN5cy5leGl0KDEpClBZRU9GClsgJD8gPSAwIF0gfHwg
>> "!B64TMP!" echo UEFTUz0wCgojIC0tLSBzZWxmLWhlYWwgdGVzdDogc2NyaXB0cyBhdXRvLXN0YXJ0IGEgZG93biBz
>> "!B64TMP!" echo dGFjayAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQplY2hvCmVjaG8gIj09PT09IHNlbGYtaGVhbCB0
>> "!B64TMP!" echo ZXN0OiB3ZWJfc2VhcmNoIC8gd2ViX3NjcmFwZSBzdGFydCBhIGRvd24gc3RhY2sgPT09PT0iCgpw
>> "!B64TMP!" echo b3J0c19mcmVlKCkgewogICIkUFkiIC0gPDwnUFlLJwppbXBvcnQgc29ja2V0LCBzeXMKZm9yIHBv
>> "!B64TMP!" echo cnQgaW4gKDk5OTAsIDk5OTEpOgogICAgcyA9IHNvY2tldC5zb2NrZXQoKTsgcy5zZXR0aW1lb3V0
>> "!B64TMP!" echo KDAuMykKICAgIGlmIHMuY29ubmVjdF9leCgoIjEyNy4wLjAuMSIsIHBvcnQpKSA9PSAwOgogICAg
>> "!B64TMP!" echo ICAgIHN5cy5leGl0KDEpCiAgICBzLmNsb3NlKCkKc3lzLmV4aXQoMCkKUFlLCn0KCmlmIHBvcnRz
>> "!B64TMP!" echo X2ZyZWU7IHRoZW4KICAjIGZha2Ugc3RhY2s6IGFuc3dlcnMgU2VhclhORyBKU09OIG9uICQxIGFu
>> "!B64TMP!" echo ZCBGaXJlY3Jhd2wgc2NyYXBlIEpTT04gb24gJDIKICBjYXQgPiAiJFRFU1RST09UL2Zha2Vfc3Rh
>> "!B64TMP!" echo Y2sucHkiIDw8J0ZBS0UnCmltcG9ydCBqc29uLCBvcywgc3lzLCB0aHJlYWRpbmcsIHRpbWUKZnJv
>> "!B64TMP!" echo bSBodHRwLnNlcnZlciBpbXBvcnQgQmFzZUhUVFBSZXF1ZXN0SGFuZGxlciwgSFRUUFNlcnZlcgpm
>> "!B64TMP!" echo cm9tIHVybGxpYi5wYXJzZSBpbXBvcnQgdXJscGFyc2UsIHBhcnNlX3FzCgpTRUFSWF9QT1JULCBG
>> "!B64TMP!" echo Q19QT1JULCBQSURGSUxFID0gaW50KHN5cy5hcmd2WzFdKSwgaW50KHN5cy5hcmd2WzJdKSwgc3lz
>> "!B64TMP!" echo LmFyZ3ZbM10Kd2l0aCBvcGVuKFBJREZJTEUsICJ3IikgYXMgZmg6CiAgICBmaC53cml0ZShzdHIo
>> "!B64TMP!" echo b3MuZ2V0cGlkKCkpKQoKY2xhc3MgU2VhcngoQmFzZUhUVFBSZXF1ZXN0SGFuZGxlcik6CiAgICBk
>> "!B64TMP!" echo ZWYgZG9fR0VUKHNlbGYpOgogICAgICAgIHEgPSBwYXJzZV9xcyh1cmxwYXJzZShzZWxmLnBhdGgp
>> "!B64TMP!" echo LnF1ZXJ5KS5nZXQoInEiLCBbIiJdKVswXQogICAgICAgIGJvZHkgPSBqc29uLmR1bXBzKHsicmVz
>> "!B64TMP!" echo dWx0cyI6IFt7CiAgICAgICAgICAgICJ0aXRsZSI6ICJGQUtFIFJFU1VMVCBmb3IgIiArIHEsCiAg
>> "!B64TMP!" echo ICAgICAgICAgICJ1cmwiOiAiaHR0cHM6Ly9leGFtcGxlLmNvbS9mYWtlIiwKICAgICAgICAgICAg
>> "!B64TMP!" echo ImNvbnRlbnQiOiAiZmFrZSBzbmlwcGV0In1dfSkuZW5jb2RlKCkKICAgICAgICBzZWxmLnNlbmRf
>> "!B64TMP!" echo cmVzcG9uc2UoMjAwKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQtVHlwZSIsICJh
>> "!B64TMP!" echo cHBsaWNhdGlvbi9qc29uIikKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LUxlbmd0
>> "!B64TMP!" echo aCIsIHN0cihsZW4oYm9keSkpKQogICAgICAgIHNlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgIHNl
>> "!B64TMP!" echo bGYud2ZpbGUud3JpdGUoYm9keSkKICAgIGRlZiBsb2dfbWVzc2FnZShzZWxmLCAqYSk6IHBhc3MK
>> "!B64TMP!" echo CmNsYXNzIEZjKEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIpOgogICAgZGVmIGRvX1BPU1Qoc2VsZik6
>> "!B64TMP!" echo CiAgICAgICAgYm9keSA9IGpzb24uZHVtcHMoeyJkYXRhIjogeyJtYXJrZG93biI6ICIjIEZBS0Ug
>> "!B64TMP!" echo TUFSS0RPV05cbmhlbGxvIGZyb20gZmFrZSBmaXJlY3Jhd2wifX0pLmVuY29kZSgpCiAgICAgICAg
>> "!B64TMP!" echo c2VsZi5zZW5kX3Jlc3BvbnNlKDIwMCkKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50
>> "!B64TMP!" echo LVR5cGUiLCAiYXBwbGljYXRpb24vanNvbiIpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29u
>> "!B64TMP!" echo dGVudC1MZW5ndGgiLCBzdHIobGVuKGJvZHkpKSkKICAgICAgICBzZWxmLmVuZF9oZWFkZXJzKCkK
>> "!B64TMP!" echo ICAgICAgICBzZWxmLndmaWxlLndyaXRlKGJvZHkpCiAgICBkZWYgbG9nX21lc3NhZ2Uoc2VsZiwg
>> "!B64TMP!" echo KmEpOiBwYXNzCgpmb3IgaGFuZGxlciwgcG9ydCBpbiAoKFNlYXJ4LCBTRUFSWF9QT1JUKSwgKEZj
>> "!B64TMP!" echo LCBGQ19QT1JUKSk6CiAgICB0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD1IVFRQU2VydmVyKCgiMTI3
>> "!B64TMP!" echo LjAuMC4xIiwgcG9ydCksIGhhbmRsZXIpLnNlcnZlX2ZvcmV2ZXIsCiAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgIGRhZW1vbj1UcnVlKS5zdGFydCgpCndoaWxlIFRydWU6CiAgICB0aW1lLnNsZWVwKDM2MDAp
>> "!B64TMP!" echo CkZBS0UKCiAgRkFLRV9QSURGSUxFPSIkVEVTVFJPT1QvZmFrZV9zdGFjay5waWQiCiAga2lsbF9m
>> "!B64TMP!" echo YWtlX3N0YWNrKCkgewogICAgaWYgWyAtZiAiJEZBS0VfUElERklMRSIgXTsgdGhlbgogICAgICBr
>> "!B64TMP!" echo aWxsICIkKGNhdCAiJEZBS0VfUElERklMRSIgMj4vZGV2L251bGwpIiAyPi9kZXYvbnVsbAogICAg
>> "!B64TMP!" echo ICBybSAtZiAiJEZBS0VfUElERklMRSIKICAgIGZpCiAgICBmb3IgXyBpbiAxIDIgMyA0IDUgNiA3
>> "!B64TMP!" echo IDggOSAxMDsgZG8KICAgICAgcG9ydHNfZnJlZSAmJiByZXR1cm4gMAogICAgICBzbGVlcCAwLjUK
>> "!B64TMP!" echo ICAgIGRvbmUKICAgIHJldHVybiAxCiAgfQoKICAjIG1vY2sgZG9ja2VyICMyOiBgY29tcG9zZSB1
>> "!B64TMP!" echo cCAtZGAgcmVhZHMgdGhlIHBvcnRzIGZyb20gLi8uZW52IGFuZCBzdGFydHMKICAjIHRoZSBmYWtl
>> "!B64TMP!" echo IHN0YWNrIChzbyBzZWxmLWhlYWwgYWN0dWFsbHkgYnJpbmdzIHRoZSBlbmRwb2ludHMgdXApCiAg
>> "!B64TMP!" echo bWtkaXIgLXAgIiRURVNUUk9PVC9iaW4yIgogIGNhdCA+ICIkVEVTVFJPT1QvYmluMi9kb2NrZXIi
>> "!B64TMP!" echo IDw8J01PQ0syJwojIS91c3IvYmluL2VudiBiYXNoCmNhc2UgIiQxIiBpbgogIGluZm8pIGV4aXQg
>> "!B64TMP!" echo MCA7OwogIGNvbXBvc2UpCiAgICBjYXNlICIkMiIgaW4KICAgICAgdmVyc2lvbikgZWNobyAiRG9j
>> "!B64TMP!" echo a2VyIENvbXBvc2UgdmVyc2lvbiB2Mi4wLjAtdGVzdCI7IGV4aXQgMCA7OwogICAgICB1cCkKICAg
>> "!B64TMP!" echo ICAgICBTRUFSWE5HX1BPUlQ9JChncmVwIC1FICdeU0VBUlhOR19QT1JUPScgLmVudiB8IGN1dCAt
>> "!B64TMP!" echo ZD0gLWYyKQogICAgICAgIEZJUkVDUkFXTF9QT1JUPSQoZ3JlcCAtRSAnXkZJUkVDUkFXTF9QT1JU
>> "!B64TMP!" echo PScgLmVudiB8IGN1dCAtZD0gLWYyKQogICAgICAgIG5vaHVwICIkRkFLRV9QWSIgIiRGQUtFX1NU
>> "!B64TMP!" echo QUNLIiAiJFNFQVJYTkdfUE9SVCIgIiRGSVJFQ1JBV0xfUE9SVCIgIiRGQUtFX1BJREZJTEUiID4v
>> "!B64TMP!" echo ZGV2L251bGwgMj4mMSAmCiAgICAgICAgZWNobyAiW21vY2tdIGNvbXBvc2UgdXAgb2sgKGZha2Ug
>> "!B64TMP!" echo c3RhY2sgc3RhcnRlZCkiCiAgICAgICAgZXhpdCAwIDs7CiAgICAgICopIGV4aXQgMCA7OwogICAg
>> "!B64TMP!" echo ZXNhYyA7OwogICopIGV4aXQgMCA7Owplc2FjCk1PQ0syCiAgY2htb2QgK3ggIiRURVNUUk9PVC9i
>> "!B64TMP!" echo aW4yL2RvY2tlciIKCiAgIyBtb2NrIGRvY2tlciAjMzogYGNvbXBvc2UgdXAgLWRgIHN1Y2NlZWRz
>> "!B64TMP!" echo IGJ1dCBzdGFydHMgTk9USElORyAoZmFpbHVyZSBwYXRoKQogIG1rZGlyIC1wICIkVEVTVFJPT1Qv
>> "!B64TMP!" echo YmluMyIKICBjYXQgPiAiJFRFU1RST09UL2JpbjMvZG9ja2VyIiA8PCdNT0NLMycKIyEvdXNyL2Jp
>> "!B64TMP!" echo bi9lbnYgYmFzaApjYXNlICIkMSIgaW4KICBpbmZvKSBleGl0IDAgOzsKICBjb21wb3NlKQogICAg
>> "!B64TMP!" echo Y2FzZSAiJDIiIGluCiAgICAgIHZlcnNpb24pIGVjaG8gIkRvY2tlciBDb21wb3NlIHZlcnNpb24g
>> "!B64TMP!" echo djIuMC4wLXRlc3QiOyBleGl0IDAgOzsKICAgICAgdXApIGVjaG8gIlttb2NrXSBjb21wb3NlIHVw
>> "!B64TMP!" echo IG9rIChub3RoaW5nIGFjdHVhbGx5IHN0YXJ0ZWQpIjsgZXhpdCAwIDs7CiAgICAgICopIGV4aXQg
>> "!B64TMP!" echo MCA7OwogICAgZXNhYyA7OwogICopIGV4aXQgMCA7Owplc2FjCk1PQ0szCiAgY2htb2QgK3ggIiRU
>> "!B64TMP!" echo RVNUUk9PVC9iaW4zL2RvY2tlciIKCiAgSEVBTF9FTlY9IkZBS0VfUFk9JFBZIEZBS0VfU1RBQ0s9
>> "!B64TMP!" echo JFRFU1RST09UL2Zha2Vfc3RhY2sucHkgRkFLRV9QSURGSUxFPSRGQUtFX1BJREZJTEUgTE9DQUxf
>> "!B64TMP!" echo U0VBUkNIX0RJUj0kVEdUX0RJUiIKCiAgIyBQaGFzZSBBIC0gZmFzdCBwYXRoOiBzdGFjayBhbHJl
>> "!B64TMP!" echo YWR5IHVwIC0+IHN0cmFpZ2h0IHRvIHJlc3VsdHMsIG5vIGJvb3QKICBub2h1cCAiJFBZIiAiJFRF
>> "!B64TMP!" echo U1RST09UL2Zha2Vfc3RhY2sucHkiIDk5OTAgOTk5MSAiJEZBS0VfUElERklMRSIgPi9kZXYvbnVs
>> "!B64TMP!" echo bCAyPiYxICYKICBzbGVlcCAxCiAgaWYgZW52ICRIRUFMX0VOViAiJFBZIiAiJFNLSUxMX0RJUi9z
>> "!B64TMP!" echo Y3JpcHRzL3dlYl9zZWFyY2gucHkiICJmYXN0IHBhdGgiIFwKICAgICAgID4gIiRURVNUUk9PVC9o
>> "!B64TMP!" echo ZWFsQS5sb2ciIDI+JjEgXAogICAgICYmIGdyZXAgLXEgIkZBS0UgUkVTVUxUIGZvciBmYXN0IHBh
>> "!B64TMP!" echo dGgiICIkVEVTVFJPT1QvaGVhbEEubG9nIiBcCiAgICAgJiYgISBncmVwIC1xICJzdGFydGluZyBp
>> "!B64TMP!" echo dCBhdXRvbWF0aWNhbGx5IiAiJFRFU1RST09UL2hlYWxBLmxvZyI7IHRoZW4KICAgIGVjaG8gIiAg
>> "!B64TMP!" echo W09LXSAgIGZhc3QgcGF0aDogc2VhcmNoIHdvcmtzIHdpdGggdGhlIHN0YWNrIGFscmVhZHkgdXAg
>> "!B64TMP!" echo KG5vIGJvb3QpIgogIGVsc2UKICAgIGVjaG8gIiAgW0ZBSUxdIGZhc3QtcGF0aCBzZWFyY2giOyBj
>> "!B64TMP!" echo YXQgIiRURVNUUk9PVC9oZWFsQS5sb2ciOyBQQVNTPTAKICBmaQoKICAjIFBoYXNlIEIgLSBzZWxm
>> "!B64TMP!" echo LWhlYWw6IHN0YWNrIGRvd24gLT4gYm9vdCAobW9jayBjb21wb3NlKSAtPiByZXRyeSAtPiByZXN1
>> "!B64TMP!" echo bHRzCiAga2lsbF9mYWtlX3N0YWNrCiAgaWYgZW52ICRIRUFMX0VOViBQQVRIPSIkVEVTVFJPT1Qv
>> "!B64TMP!" echo YmluMjokUEFUSCIgXAogICAgICAgIiRQWSIgIiRTS0lMTF9ESVIvc2NyaXB0cy93ZWJfc2VhcmNo
>> "!B64TMP!" echo LnB5IiAic2VsZmhlYWwgc2VhcmNoIiBcCiAgICAgICA+ICIkVEVTVFJPT1QvaGVhbEIubG9nIiAy
>> "!B64TMP!" echo PiYxIFwKICAgICAmJiBncmVwIC1xICJzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IiAiJFRFU1RS
>> "!B64TMP!" echo T09UL2hlYWxCLmxvZyIgXAogICAgICYmIGdyZXAgLXEgIkZBS0UgUkVTVUxUIGZvciBzZWxmaGVh
>> "!B64TMP!" echo bCBzZWFyY2giICIkVEVTVFJPT1QvaGVhbEIubG9nIjsgdGhlbgogICAgZWNobyAiICBbT0tdICAg
>> "!B64TMP!" echo c2VsZi1oZWFsOiB3ZWJfc2VhcmNoIGJvb3RlZCB0aGUgZG93biBzdGFjayBhbmQgcmV0cmllZCIK
>> "!B64TMP!" echo ICBlbHNlCiAgICBlY2hvICIgIFtGQUlMXSB3ZWJfc2VhcmNoIHNlbGYtaGVhbCI7IGNhdCAiJFRF
>> "!B64TMP!" echo U1RST09UL2hlYWxCLmxvZyI7IFBBU1M9MAogIGZpCgogICMgUGhhc2UgQjIgLSBzZWxmLWhlYWwg
>> "!B64TMP!" echo Zm9yIHRoZSBzY3JhcGVyCiAga2lsbF9mYWtlX3N0YWNrCiAgaWYgZW52ICRIRUFMX0VOViBQQVRI
>> "!B64TMP!" echo PSIkVEVTVFJPT1QvYmluMjokUEFUSCIgXAogICAgICAgIiRQWSIgIiRTS0lMTF9ESVIvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfc2NyYXBlLnB5IiAiaHR0cHM6Ly9leGFtcGxlLmNvbS9hcnRpY2xlIiBcCiAgICAgICA+
>> "!B64TMP!" echo ICIkVEVTVFJPT1QvaGVhbEIyLmxvZyIgMj4mMSBcCiAgICAgJiYgZ3JlcCAtcSAic3RhcnRpbmcg
>> "!B64TMP!" echo aXQgYXV0b21hdGljYWxseSIgIiRURVNUUk9PVC9oZWFsQjIubG9nIiBcCiAgICAgJiYgZ3JlcCAt
>> "!B64TMP!" echo cSAiRkFLRSBNQVJLRE9XTiIgIiRURVNUUk9PVC9oZWFsQjIubG9nIjsgdGhlbgogICAgZWNobyAi
>> "!B64TMP!" echo ICBbT0tdICAgc2VsZi1oZWFsOiB3ZWJfc2NyYXBlIGJvb3RlZCB0aGUgZG93biBzdGFjayBhbmQg
>> "!B64TMP!" echo cmV0cmllZCIKICBlbHNlCiAgICBlY2hvICIgIFtGQUlMXSB3ZWJfc2NyYXBlIHNlbGYtaGVhbCI7
>> "!B64TMP!" echo IGNhdCAiJFRFU1RST09UL2hlYWxCMi5sb2ciOyBQQVNTPTAKICBmaQoKICAjIFBoYXNlIEMgLSBm
>> "!B64TMP!" echo YWlsdXJlOiBzdGFjayBjYW5ub3QgY29tZSB1cCAtPiBjbGVhciBndWlkYW5jZSwgZXhpdCAxCiAg
>> "!B64TMP!" echo a2lsbF9mYWtlX3N0YWNrCiAgaWYgZW52ICRIRUFMX0VOViBQQVRIPSIkVEVTVFJPT1QvYmluMzok
>> "!B64TMP!" echo UEFUSCIgTE9DQUxfU0VBUkNIX1JFQURZX1RJTUVPVVQ9MiBcCiAgICAgICAiJFBZIiAiJFNLSUxM
>> "!B64TMP!" echo X0RJUi9zY3JpcHRzL3dlYl9zZWFyY2gucHkiICJkb29tZWQiIFwKICAgICAgID4gIiRURVNUUk9P
>> "!B64TMP!" echo VC9oZWFsQy5sb2ciIDI+JjE7IHRoZW4KICAgIGVjaG8gIiAgW0ZBSUxdIHNlbGYtaGVhbCBmYWls
>> "!B64TMP!" echo dXJlIHBhdGggc2hvdWxkIGV4aXQgbm9uLXplcm8iOyBQQVNTPTAKICBlbGlmIGdyZXAgLXEgImNv
>> "!B64TMP!" echo dWxkIG5vdCBiZSBzdGFydGVkIiAiJFRFU1RST09UL2hlYWxDLmxvZyIgXAogICAgICAgJiYgZ3Jl
>> "!B64TMP!" echo cCAtcSAiZGlkIG5vdCBiZWNvbWUgcmVhZHkiICIkVEVTVFJPT1QvaGVhbEMubG9nIjsgdGhlbgog
>> "!B64TMP!" echo ICAgZWNobyAiICBbT0tdICAgc2VsZi1oZWFsIGZhaWx1cmU6IGNsZWFyIGd1aWRhbmNlLCBub24t
>> "!B64TMP!" echo emVybyBleGl0IgogIGVsc2UKICAgIGVjaG8gIiAgW0ZBSUxdIHNlbGYtaGVhbCBmYWlsdXJlIG1l
>> "!B64TMP!" echo c3NhZ2UgbWlzc2luZyI7IGNhdCAiJFRFU1RST09UL2hlYWxDLmxvZyI7IFBBU1M9MAogIGZpCiAg
>> "!B64TMP!" echo a2lsbF9mYWtlX3N0YWNrCmVsc2UKICBlY2hvICIgIFtXQVJOXSBwb3J0cyA5OTkwLzk5OTEgYXJl
>> "!B64TMP!" echo IGluIHVzZSAtIHNraXBwaW5nIHRoZSBzZWxmLWhlYWwgdGVzdCIKZmkKCiMgLS0tIGFjY291bnQt
>> "!B64TMP!" echo bW9kZSBpbnN0YWxsOiBhIEZpcmVjcmF3bCBhY2NvdW50IGluc3RhbGxzIGFsbCAyNCB0b29scyAt
>> "!B64TMP!" echo LS0tLS0KZWNobwplY2hvICI9PT09PSBhY2NvdW50LW1vZGUgaW5zdGFsbDogZmFrZSBGaXJlY3Jh
>> "!B64TMP!" echo d2wgYWNjb3VudCAtPiBhbGwgMjQgdG9vbHMgPT09PT0iCgpUR1QzPSIkVEVTVFJPT1QvdGFyZ2V0
>> "!B64TMP!" echo MyIKIyBhbnN3ZXJzOiB0YXJnZXQsIHNlYXJ4bmcgcG9ydCwgZmlyZWNyYXdsIHBvcnQsIExMTT8g
>> "!B64TMP!" echo LT4gbiwKIyAgICAgICAgICBhY2NvdW50PyAtPiB5LCBrZXksIFVSTCAoRW50ZXIgPSBkZWZhdWx0
>> "!B64TMP!" echo KSwgY29uZmlybSAtPiB5CnByaW50ZiAnJXNcbiVzXG4lc1xuJXNcbiVzXG4lc1xuJXNcbiVzXG4n
>> "!B64TMP!" echo IFwKICAiJFRHVDMiICIiICIiICJuIiAieSIgImZjLWUyZS10ZXN0LWtleS0xMjMiICIiICJ5IiBc
>> "!B64TMP!" echo CiAgfCAiJFNSQ19ESVIvaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giID4gIiRURVNUUk9PVC9pbnN0
>> "!B64TMP!" echo My5sb2ciIDI+JjEKUkMzPSQ/CmVjaG8gIkluc3RhbGxlciBleGl0IGNvZGU6ICRSQzMiCnRhaWwg
>> "!B64TMP!" echo LTIwICIkVEVTVFJPT1QvaW5zdDMubG9nIgplY2hvICItLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLSIKCmlmIFsgIiRSQzMiID0gMCBdIFwKICAgJiYgZ3JlcCAtcSAiSW5zdGFsbGluZyB0
>> "!B64TMP!" echo aGUgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCBza2lsbCIgIiRURVNUUk9PVC9pbnN0My5sb2ciIFwK
>> "!B64TMP!" echo ICAgJiYgISBncmVwIC1xICJjb3JlLW9ubHkiICIkVEVTVFJPT1QvaW5zdDMubG9nIjsgdGhlbgog
>> "!B64TMP!" echo IGVjaG8gIiAgW09LXSAgIGFjY291bnQtbW9kZSBpbnN0YWxsIGNvbXBsZXRlZCAobm8gY29yZS1v
>> "!B64TMP!" echo bmx5IHRyaW0pIgplbHNlCiAgZWNobyAiICBbRkFJTF0gYWNjb3VudC1tb2RlIGluc3RhbGwiOyBQ
>> "!B64TMP!" echo QVNTPTAKZmkKCmlmIGdyZXAgLXEgIl5GSVJFQ1JBV0xfQVBJX1VSTD1odHRwczovL2FwaS5maXJl
>> "!B64TMP!" echo Y3Jhd2wuZGV2JCIgIiRUR1QzLy5lbnYiIFwKICAgJiYgZ3JlcCAtcSAiXkZJUkVDUkFXTF9BUElf
>> "!B64TMP!" echo S0VZPWZjLWUyZS10ZXN0LWtleS0xMjMkIiAiJFRHVDMvLmVudiI7IHRoZW4KICBlY2hvICIgIFtP
>> "!B64TMP!" echo S10gICAuZW52IGhvbGRzIHRoZSBhY2NvdW50IGNyZWRlbnRpYWxzIgplbHNlCiAgZWNobyAiICBb
>> "!B64TMP!" echo RkFJTF0gLmVudiBpcyBtaXNzaW5nIHRoZSBhY2NvdW50IGNyZWRlbnRpYWxzIjsgUEFTUz0wCmZp
>> "!B64TMP!" echo CgppZiBncmVwIC1xICJ3ZWJfbW9uaXRvcl9jcmVhdGUiICIkU0tJTExfRElSL1NLSUxMLm1kIiBc
>> "!B64TMP!" echo CiAgICYmICEgZ3JlcCAtcSAiNSB0b29sczogc2VhcmNoLCBzY3JhcGUsIG1hcCwgY3Jhd2wsIGNy
>> "!B64TMP!" echo YXdsIHN0YXR1cyIgIiRTS0lMTF9ESVIvU0tJTEwubWQiIFwKICAgJiYgWyAhIC1lICIkU0tJTExf
>> "!B64TMP!" echo RElSL1NLSUxMLWNvcmUubWQiIF0gXAogICAmJiBbICEgLWUgIiRUR1QzL2xvY2FsLXdlYi1zZWFy
>> "!B64TMP!" echo Y2gvU0tJTEwtY29yZS5tZCIgXTsgdGhlbgogIGVjaG8gIiAgW09LXSAgIFNLSUxMLm1kIGlzIHRo
>> "!B64TMP!" echo ZSBmdWxsIDI0LXRvb2wgdmFyaWFudCAoU0tJTEwtY29yZS5tZCBjbGVhbmVkIHVwKSIKZWxzZQog
>> "!B64TMP!" echo IGVjaG8gIiAgW0ZBSUxdIFNLSUxMLm1kIHZhcmlhbnQgd3JvbmcgaW4gYWNjb3VudCBtb2RlIjsg
>> "!B64TMP!" echo UEFTUz0wCmZpCgpBTExfU0tJTExfRklMRVM9IlNLSUxMLm1kIHNjcmlwdHMvY29uZmlnLnB5IHNj
>> "!B64TMP!" echo cmlwdHMvZW5zdXJlX3N0YWNrLnB5IHNjcmlwdHMvZmlyZWNyYXdsX2FwaS5weSBcCiAgICAgICAg
>> "!B64TMP!" echo IHNjcmlwdHMvd2ViX3NlYXJjaC5weSBzY3JpcHRzL3dlYl9zY3JhcGUucHkgc2NyaXB0cy93ZWJf
>> "!B64TMP!" echo bWFwLnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfY3Jhd2wucHkgc2NyaXB0cy93ZWJfY3Jhd2xf
>> "!B64TMP!" echo c3RhdHVzLnB5IHNjcmlwdHMvd2ViX2FnZW50LnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfYWdl
>> "!B64TMP!" echo bnRfc3RhdHVzLnB5IHNjcmlwdHMvd2ViX2ludGVyYWN0LnB5IFwKICAgICAgICAgc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfaW50ZXJhY3Rfc3RvcC5weSBzY3JpcHRzL3dlYl9wYXJzZS5weSBcCiAgICAgICAgIHNjcmlw
>> "!B64TMP!" echo dHMvd2ViX21vbml0b3JfY3JlYXRlLnB5IHNjcmlwdHMvd2ViX21vbml0b3JfbGlzdC5weSBcCiAg
>> "!B64TMP!" echo ICAgICAgIHNjcmlwdHMvd2ViX21vbml0b3JfZ2V0LnB5IHNjcmlwdHMvd2ViX21vbml0b3JfdXBk
>> "!B64TMP!" echo YXRlLnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfbW9uaXRvcl9kZWxldGUucHkgc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfbW9uaXRvcl9ydW4ucHkgXAogICAgICAgICBzY3JpcHRzL3dlYl9tb25pdG9yX2NoZWNrcy5w
>> "!B64TMP!" echo eSBzY3JpcHRzL3dlYl9tb25pdG9yX2NoZWNrLnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfcmVz
>> "!B64TMP!" echo ZWFyY2hfc2VhcmNoLnB5IHNjcmlwdHMvd2ViX3Jlc2VhcmNoX2luc3BlY3QucHkgXAogICAgICAg
>> "!B64TMP!" echo ICBzY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IHNjcmlwdHMvd2ViX3Jlc2VhcmNoX3Jl
>> "!B64TMP!" echo YWQucHkgXAogICAgICAgICBzY3JpcHRzL3dlYl9naXRodWJfc2VhcmNoLnB5IHNjcmlwdHMvd2Vi
>> "!B64TMP!" echo X2RldmVsb3Blcl9zZWFyY2gucHkiCkFDQ09VTlRfUEFTUz0xCmZvciBmIGluICRBTExfU0tJTExf
>> "!B64TMP!" echo RklMRVM7IGRvCiAgaWYgWyAtcyAiJFNLSUxMX0RJUi8kZiIgXTsgdGhlbiA6OyBlbHNlCiAgICBl
>> "!B64TMP!" echo Y2hvICIgIFtGQUlMXSBhY2NvdW50LW1vZGUgc2tpbGwgbWlzc2luZzogJGYiCiAgICBBQ0NPVU5U
>> "!B64TMP!" echo X1BBU1M9MDsgUEFTUz0wCiAgZmkKZG9uZQppZiBbICIkQUNDT1VOVF9QQVNTIiA9IDEgXTsgdGhl
>> "!B64TMP!" echo bgogIGVjaG8gIiAgW09LXSAgIGFsbCAyNCB0b29sIHNjcmlwdHMgKyBzaGFyZWQgbW9kdWxlcyBp
>> "!B64TMP!" echo biB0aGUgYWNjb3VudC1tb2RlIHNraWxsIgpmaQoKIyAtLS0gYWNjb3VudC1tb2RlOiBmaXJlY3Jh
>> "!B64TMP!" echo d2xfYXBpLnB5IG11c3QgcGljayB0aGUgLmVudiBjcmVkZW50aWFscyB1cCAtLS0tLS0tCiIkUFki
>> "!B64TMP!" echo IC0gPDwnUFlFT0YzJwppbXBvcnQgc3lzLCBvcwpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5l
>> "!B64TMP!" echo eHBhbmR1c2VyKCJ+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cyIpKQpm
>> "!B64TMP!" echo b3IgdmFyIGluICgiTE9DQUxfU0VBUkNIX0RJUiIsICJGSVJFQ1JBV0xfQVBJX1VSTCIsICJGSVJF
>> "!B64TMP!" echo Q1JBV0xfQVBJX0tFWSIpOgogICAgb3MuZW52aXJvbi5wb3AodmFyLCBOb25lKQppbXBvcnQgZmly
>> "!B64TMP!" echo ZWNyYXdsX2FwaSBhcyBmYwppZiBmYy5iYXNlX3VybCgpID09ICJodHRwczovL2FwaS5maXJlY3Jh
>> "!B64TMP!" echo d2wuZGV2IjoKICAgIHByaW50KCIgIFtPS10gICBmaXJlY3Jhd2xfYXBpLmJhc2VfdXJsKCkgcmVh
>> "!B64TMP!" echo ZHMgRklSRUNSQVdMX0FQSV9VUkwgZnJvbSB0aGUgaW5zdGFsbCAuZW52IikKZWxzZToKICAgIHBy
>> "!B64TMP!" echo aW50KCIgIFtGQUlMXSBmaXJlY3Jhd2xfYXBpLmJhc2VfdXJsKCkgPSAlcyIgJSBmYy5iYXNlX3Vy
>> "!B64TMP!" echo bCgpKTsgc3lzLmV4aXQoMSkKaWYgbm90IGZjLmlzX2xvY2FsKCk6CiAgICBwcmludCgiICBbT0td
>> "!B64TMP!" echo ICAgZmlyZWNyYXdsX2FwaS5pc19sb2NhbCgpIGlzIEZhbHNlIChyZW1vdGUgYWNjb3VudCBtb2Rl
>> "!B64TMP!" echo KSIpCmVsc2U6CiAgICBwcmludCgiICBbRkFJTF0gZmlyZWNyYXdsX2FwaS5pc19sb2NhbCgpIHNo
>> "!B64TMP!" echo b3VsZCBiZSBGYWxzZSBpbiBhY2NvdW50IG1vZGUiKTsgc3lzLmV4aXQoMSkKaGRycyA9IGZjLmF1
>> "!B64TMP!" echo dGhfaGVhZGVycygpCmlmIGhkcnMuZ2V0KCJBdXRob3JpemF0aW9uIikgPT0gIkJlYXJlciBmYy1l
>> "!B64TMP!" echo MmUtdGVzdC1rZXktMTIzIjoKICAgIHByaW50KCIgIFtPS10gICBhdXRoX2hlYWRlcnMoKSBjYXJy
>> "!B64TMP!" echo aWVzIHRoZSBCZWFyZXIga2V5IGZyb20gdGhlIGluc3RhbGwgLmVudiIpCmVsc2U6CiAgICBwcmlu
>> "!B64TMP!" echo dCgiICBbRkFJTF0gQXV0aG9yaXphdGlvbiBoZWFkZXIgd3Jvbmc6ICVyIiAlIGhkcnMuZ2V0KCJB
>> "!B64TMP!" echo dXRob3JpemF0aW9uIikpOyBzeXMuZXhpdCgxKQpQWUVPRjMKWyAkPyA9IDAgXSB8fCBQQVNTPTAK
>> "!B64TMP!" echo CiMgLS0tIGFjY291bnQtbW9kZTogZXZlcnkgdG9vbCBzY3JpcHQgcm91dGVzIHRvIHRoZSBjbG91
>> "!B64TMP!" echo ZCBBUEkgLS0tLS0tLS0tLS0tLS0tCiIkUFkiIC0gPDwnUFlFT0Y0JwppbXBvcnQgc3lzLCBvcwpz
>> "!B64TMP!" echo eXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5leHBhbmR1c2VyKCJ+Ly5hZ2VudHMvc2tpbGxzL2xv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2gvc2NyaXB0cyIpKQpmb3IgdmFyIGluICgiTE9DQUxfU0VBUkNIX0RJUiIs
>> "!B64TMP!" echo ICJGSVJFQ1JBV0xfQVBJX1VSTCIsICJGSVJFQ1JBV0xfQVBJX0tFWSIpOgogICAgb3MuZW52aXJv
>> "!B64TMP!" echo bi5wb3AodmFyLCBOb25lKQpjaGVja3MgPSBbCiAgICAoIndlYl9tYXAiLCAgICAgICAgICAgICAg
>> "!B64TMP!" echo Ii92MS9tYXAiKSwKICAgICgid2ViX2NyYXdsIiwgICAgICAgICAgICAiL3YxL2NyYXdsIiksCiAg
>> "!B64TMP!" echo ICAoIndlYl9jcmF3bF9zdGF0dXMiLCAgICAgIi92MS9jcmF3bCIpLAogICAgKCJ3ZWJfYWdlbnQi
>> "!B64TMP!" echo LCAgICAgICAgICAgICIvdjEvYWdlbnQiKSwKICAgICgid2ViX2FnZW50X3N0YXR1cyIsICAgICAi
>> "!B64TMP!" echo L3YxL2FnZW50IiksCiAgICAoIndlYl9pbnRlcmFjdCIsICAgICAgICAgIi92MS9pbnRlcmFjdCIp
>> "!B64TMP!" echo LAogICAgKCJ3ZWJfaW50ZXJhY3Rfc3RvcCIsICAgICIvdjEvaW50ZXJhY3QiKSwKICAgICgid2Vi
>> "!B64TMP!" echo X3BhcnNlIiwgICAgICAgICAgICAiL3YxL3BhcnNlIiksCiAgICAoIndlYl9tb25pdG9yX2NyZWF0
>> "!B64TMP!" echo ZSIsICAgIi92MS9tb25pdG9yIiksCiAgICAoIndlYl9tb25pdG9yX2xpc3QiLCAgICAgIi92MS9t
>> "!B64TMP!" echo b25pdG9yIiksCiAgICAoIndlYl9tb25pdG9yX2dldCIsICAgICAgIi92MS9tb25pdG9yIiksCiAg
>> "!B64TMP!" echo ICAoIndlYl9tb25pdG9yX3VwZGF0ZSIsICAgIi92MS9tb25pdG9yIiksCiAgICAoIndlYl9tb25p
>> "!B64TMP!" echo dG9yX2RlbGV0ZSIsICAgIi92MS9tb25pdG9yIiksCiAgICAoIndlYl9tb25pdG9yX3J1biIsICAg
>> "!B64TMP!" echo ICAgIi92MS9tb25pdG9yIiksCiAgICAoIndlYl9tb25pdG9yX2NoZWNrcyIsICAgIi92MS9tb25p
>> "!B64TMP!" echo dG9yIiksCiAgICAoIndlYl9tb25pdG9yX2NoZWNrIiwgICAgIi92MS9tb25pdG9yIiksCiAgICAo
>> "!B64TMP!" echo IndlYl9yZXNlYXJjaF9zZWFyY2giLCAgIi92MS9yZXNlYXJjaC9zZWFyY2gvcGFwZXJzIiksCiAg
>> "!B64TMP!" echo ICAoIndlYl9yZXNlYXJjaF9pbnNwZWN0IiwgIi92MS9yZXNlYXJjaC9wYXBlcnMiKSwKICAgICgi
>> "!B64TMP!" echo d2ViX3Jlc2VhcmNoX3JlbGF0ZWQiLCAiL3YxL3Jlc2VhcmNoL3JlbGF0ZWQiKSwKICAgICgid2Vi
>> "!B64TMP!" echo X3Jlc2VhcmNoX3JlYWQiLCAgICAiL3YxL3Jlc2VhcmNoL3BhcGVycyIpLAogICAgKCJ3ZWJfZ2l0
>> "!B64TMP!" echo aHViX3NlYXJjaCIsICAgICIvdjEvcmVzZWFyY2gvc2VhcmNoL2dpdGh1YiIpLAogICAgKCJ3ZWJf
>> "!B64TMP!" echo ZGV2ZWxvcGVyX3NlYXJjaCIsICIvdjEvZGV2ZWxvcGVyL3NlYXJjaCIpLApdCmZvciBuYW1lLCBz
>> "!B64TMP!" echo dWZmaXggaW4gY2hlY2tzOgogICAgbW9kID0gX19pbXBvcnRfXyhuYW1lKQogICAgZW5kcG9pbnQg
>> "!B64TMP!" echo PSBtb2QuRU5EUE9JTlQKICAgIGlmIGVuZHBvaW50LnN0YXJ0c3dpdGgoImh0dHBzOi8vYXBpLmZp
>> "!B64TMP!" echo cmVjcmF3bC5kZXYiKSBhbmQgZW5kcG9pbnQuZW5kc3dpdGgoc3VmZml4KToKICAgICAgICBwcmlu
>> "!B64TMP!" echo dCgiICBbT0tdICAgJXMuRU5EUE9JTlQgPSAlcyIgJSAobmFtZSwgZW5kcG9pbnQpKQogICAgZWxz
>> "!B64TMP!" echo ZToKICAgICAgICBwcmludCgiICBbRkFJTF0gJXMuRU5EUE9JTlQgPSAlcyAoZXhwZWN0ZWQgY2xv
>> "!B64TMP!" echo dWQgQVBJICsgJXMpIiAlIChuYW1lLCBlbmRwb2ludCwgc3VmZml4KSkKICAgICAgICBzeXMuZXhp
>> "!B64TMP!" echo dCgxKQpwcmludCgiICBbT0tdICAgYWxsIDIyIEZpcmVjcmF3bCB0b29sIHNjcmlwdHMgcm91dGUg
>> "!B64TMP!" echo dG8gdGhlIGNsb3VkIEFQSSIpClBZRU9GNApbICQ/ID0gMCBdIHx8IFBBU1M9MAoKIyAtLS0gZG9j
>> "!B64TMP!" echo a2VyIGF1dG8tc3RhcnQgdGVzdDogZW5naW5lIGRvd24gLT4gaW5zdGFsbGVyIHN0YXJ0cyBpdCAt
>> "!B64TMP!" echo LS0tLS0tLS0tCmVjaG8KZWNobyAiPT09PT0gZG9ja2VyIGF1dG8tc3RhcnQgdGVzdDogaW5zdGFs
>> "!B64TMP!" echo bGVyIGJvb3RzIGEgZG93biBlbmdpbmUgPT09PT0iCgojIG1vY2sgZG9ja2VyICM0OiBlbmdpbmUg
>> "!B64TMP!" echo RE9XTiB1bnRpbCBhIG1vY2sgJ3N5c3RlbWN0bCBzdGFydCcgZmxpcHMgaXQgdXAKbWtkaXIgLXAg
>> "!B64TMP!" echo IiRURVNUUk9PVC9iaW40IgpjYXQgPiAiJFRFU1RST09UL2JpbjQvZG9ja2VyIiA8PCdNT0NLNCcK
>> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaApjYXNlICIkMSIgaW4KICBpbmZvKQogICAgWyAtZiAiJERPQ0tF
>> "!B64TMP!" echo Ul9VUF9NQVJLRVIiIF0gJiYgZXhpdCAwCiAgICBleGl0IDEgOzsKICBjb21wb3NlKQogICAgY2Fz
>> "!B64TMP!" echo ZSAiJDIiIGluCiAgICAgIHZlcnNpb24pIGVjaG8gIkRvY2tlciBDb21wb3NlIHZlcnNpb24gdjIu
>> "!B64TMP!" echo MC4wLXRlc3QiOyBleGl0IDAgOzsKICAgICAgKikgZWNobyAiW21vY2tdIG9rIjsgZXhpdCAwIDs7
>> "!B64TMP!" echo CiAgICBlc2FjIDs7CiAgKikgZXhpdCAwIDs7CmVzYWMKTU9DSzQKY2F0ID4gIiRURVNUUk9PVC9i
>> "!B64TMP!" echo aW40L3N5c3RlbWN0bCIgPDwnTU9DSzRTJwojIS91c3IvYmluL2VudiBiYXNoCiMgbW9jayBzeXN0
>> "!B64TMP!" echo ZW1kIGNvbnRyb2w6ICdzdGFydCA8dW5pdD4nIGJyaW5ncyB0aGUgZW5naW5lIHVwClsgIiQxIiA9
>> "!B64TMP!" echo ICJzdGFydCIgXSAmJiA6ID4gIiRET0NLRVJfVVBfTUFSS0VSIgpleGl0IDAKTU9DSzRTCmNobW9k
>> "!B64TMP!" echo ICt4ICIkVEVTVFJPT1QvYmluNC9kb2NrZXIiICIkVEVTVFJPT1QvYmluNC9zeXN0ZW1jdGwiCgpU
>> "!B64TMP!" echo R1QyPSIkVEVTVFJPT1QvdGFyZ2V0MiIKVVBNQVJLPSIkVEVTVFJPT1QvZG9ja2VyX3VwLm1hcmtl
>> "!B64TMP!" echo ciIKcHJpbnRmICclc1xuJXNcbiVzXG4lc1xuJXNcbiVzXG4nICIkVEdUMiIgIiIgIiIgIm4iICJu
>> "!B64TMP!" echo IiAieSIgXAogIHwgZW52IERPQ0tFUl9VUF9NQVJLRVI9IiRVUE1BUksiIFBBVEg9IiRURVNUUk9P
>> "!B64TMP!" echo VC9iaW40OiRQQVRIIiBcCiAgICAiJFNSQ19ESVIvaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giID4g
>> "!B64TMP!" echo IiRURVNUUk9PVC9pbnN0RC5sb2ciIDI+JjEKRFJDPSQ/CmlmIFsgIiREUkMiID0gMCBdICYmIGdy
>> "!B64TMP!" echo ZXAgLXEgInRyeWluZyB0byBzdGFydCBpdCIgIiRURVNUUk9PVC9pbnN0RC5sb2ciIFwKICAgJiYg
>> "!B64TMP!" echo Z3JlcCAtcSAiTGF1bmNoZWQgRG9ja2VyIGluIHRoZSBiYWNrZ3JvdW5kIiAiJFRFU1RST09UL2lu
>> "!B64TMP!" echo c3RELmxvZyIgXAogICAmJiBncmVwIC1xICJlbmdpbmUgaXMgb25saW5lIiAiJFRFU1RST09UL2lu
>> "!B64TMP!" echo c3RELmxvZyIgXAogICAmJiBbIC1mICIkVVBNQVJLIiBdICYmIFsgLXMgIiRUR1QyL2RvY2tlci1j
>> "!B64TMP!" echo b21wb3NlLnltbCIgXTsgdGhlbgogIGVjaG8gIiAgW09LXSAgIGF1dG8tc3RhcnQ6IGluc3RhbGxl
>> "!B64TMP!" echo ciBsYXVuY2hlZCB0aGUgZW5naW5lLCB3YWl0ZWQsIGZpbmlzaGVkIgplbHNlCiAgZWNobyAiICBb
>> "!B64TMP!" echo RkFJTF0gZG9ja2VyIGF1dG8tc3RhcnQgaW5zdGFsbCI7IHRhaWwgLTIwICIkVEVTVFJPT1QvaW5z
>> "!B64TMP!" echo dEQubG9nIjsgUEFTUz0wCmZpCgojIG1vY2sgZG9ja2VyICM1OiBlbmdpbmUgZG93biBhbmQgTk9U
>> "!B64TMP!" echo SElORyBjYW4gc3RhcnQgaXQgLT4gY2xlYW4gZmFpbHVyZQpta2RpciAtcCAiJFRFU1RST09UL2Jp
>> "!B64TMP!" echo bjUiCmNhdCA+ICIkVEVTVFJPT1QvYmluNS9kb2NrZXIiIDw8J01PQ0s1JwojIS91c3IvYmluL2Vu
>> "!B64TMP!" echo diBiYXNoCmNhc2UgIiQxIiBpbgogIGluZm8pIGV4aXQgMSA7OwogICopIGV4aXQgMCA7Owplc2Fj
>> "!B64TMP!" echo Ck1PQ0s1CmNobW9kICt4ICIkVEVTVFJPT1QvYmluNS9kb2NrZXIiCmZvciBtIGluIHN5c3RlbWN0
>> "!B64TMP!" echo bCBzZXJ2aWNlIHN1ZG87IGRvCiAgcHJpbnRmICcjIS91c3IvYmluL2VudiBiYXNoXG5leGl0IDFc
>> "!B64TMP!" echo bicgPiAiJFRFU1RST09UL2JpbjUvJG0iCiAgY2htb2QgK3ggIiRURVNUUk9PVC9iaW41LyRtIgpk
>> "!B64TMP!" echo b25lCnByaW50ZiAnJXNcbiVzXG4lc1xuJXNcbiVzXG4lc1xuJyAiJFRFU1RST09UL3RhcmdldDUi
>> "!B64TMP!" echo ICIiICIiICJuIiAibiIgInkiIFwKICB8IGVudiBQQVRIPSIkVEVTVFJPT1QvYmluNTokUEFUSCIg
>> "!B64TMP!" echo IiRTUkNfRElSL2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoIiBcCiAgICA+ICIkVEVTVFJPT1QvaW5z
>> "!B64TMP!" echo dEQyLmxvZyIgMj4mMQpEMlJDPSQ/CmlmIFsgIiREMlJDIiAhPSAwIF0gXAogICAmJiBncmVwIC1x
>> "!B64TMP!" echo ICJDb3VsZCBub3Qgc3RhcnQgdGhlIERvY2tlciBlbmdpbmUiICIkVEVTVFJPT1QvaW5zdEQyLmxv
>> "!B64TMP!" echo ZyI7IHRoZW4KICBlY2hvICIgIFtPS10gICBhdXRvLXN0YXJ0IGZhaWx1cmU6IGNsZWFuIGVycm9y
>> "!B64TMP!" echo ICsgZXhpdCAxIHdoZW4gbm90aGluZyBjYW4gc3RhcnQgaXQiCmVsc2UKICBlY2hvICIgIFtGQUlM
>> "!B64TMP!" echo XSBleHBlY3RlZCBjbGVhbiBmYWlsdXJlIHdoZW4gdGhlIGVuZ2luZSBjYW5ub3QgYmUgc3RhcnRl
>> "!B64TMP!" echo ZCIKICB0YWlsIC0yMCAiJFRFU1RST09UL2luc3REMi5sb2ciOyBQQVNTPTAKZmkKCiMgbW9jayBk
>> "!B64TMP!" echo b2NrZXIgIzY6IHN5c3RlbWN0bCAnc3RhcnRzJyB0aGUgZW5naW5lIGJ1dCBkb2NrZXIgaW5mbyBu
>> "!B64TMP!" echo ZXZlciB3b3Jrcwpta2RpciAtcCAiJFRFU1RST09UL2JpbjYiCmNwICIkVEVTVFJPT1QvYmluNS9k
>> "!B64TMP!" echo b2NrZXIiICIkVEVTVFJPT1QvYmluNi9kb2NrZXIiCnByaW50ZiAnIyEvdXNyL2Jpbi9lbnYgYmFz
>> "!B64TMP!" echo aFxuZXhpdCAwXG4nID4gIiRURVNUUk9PVC9iaW42L3N5c3RlbWN0bCIKY2htb2QgK3ggIiRURVNU
>> "!B64TMP!" echo Uk9PVC9iaW42L2RvY2tlciIgIiRURVNUUk9PVC9iaW42L3N5c3RlbWN0bCIKcHJpbnRmICclc1xu
>> "!B64TMP!" echo JXNcbiVzXG4lc1xuJXNcbiVzXG4nICIkVEVTVFJPT1QvdGFyZ2V0NiIgIiIgIiIgIm4iICJuIiAi
>> "!B64TMP!" echo eSIgXAogIHwgZW52IExPQ0FMX1NFQVJDSF9ET0NLRVJfVElNRU9VVD0yIFBBVEg9IiRURVNUUk9P
>> "!B64TMP!" echo VC9iaW42OiRQQVRIIiBcCiAgICAiJFNSQ19ESVIvaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giID4g
>> "!B64TMP!" echo IiRURVNUUk9PVC9pbnN0RDMubG9nIiAyPiYxCkQzUkM9JD8KaWYgWyAiJEQzUkMiICE9IDAgXSAm
>> "!B64TMP!" echo JiBncmVwIC1xICJkaWQgbm90IGNvbWUgb25saW5lIiAiJFRFU1RST09UL2luc3REMy5sb2ciOyB0
>> "!B64TMP!" echo aGVuCiAgZWNobyAiICBbT0tdICAgZW5naW5lLXdhaXQgdGltZW91dDogY2xlYW4gZXJyb3IgYWZ0
>> "!B64TMP!" echo ZXIgTE9DQUxfU0VBUkNIX0RPQ0tFUl9USU1FT1VUIgplbHNlCiAgZWNobyAiICBbRkFJTF0gZXhw
>> "!B64TMP!" echo ZWN0ZWQgdGltZW91dCBmYWlsdXJlIHdoZW4gdGhlIGVuZ2luZSBuZXZlciBjb21lcyBvbmxpbmUi
>> "!B64TMP!" echo CiAgdGFpbCAtMjAgIiRURVNUUk9PVC9pbnN0RDMubG9nIjsgUEFTUz0wCmZpCgojIC0tLSBub3cg
>> "!B64TMP!" echo cnVuIHRoZSB1bmluc3RhbGxlciAoa2VlcCBmb2xkZXIpIGFuZCB2ZXJpZnkgdGhlIHNraWxsIGlz
>> "!B64TMP!" echo IHJlbW92ZWQgLS0KZWNobwplY2hvICI9PT09PSBydW5uaW5nIHVuaW5zdGFsbGVyIChhbnN3ZXJp
>> "!B64TMP!" echo bmcgeSwgdGhlbiBuIGZvciBmb2xkZXIgZGVsZXRlKSA9PT09PSIKcHJpbnRmICd5XG5uXG4nIHwg
>> "!B64TMP!" echo IiRUR1RfRElSL3VuaW5zdGFsbC5zaCIgPiAiJFRFU1RST09UL3VuaW5zdGFsbC5sb2ciIDI+JjEK
>> "!B64TMP!" echo VVJDPSQ/CmVjaG8gIlVuaW5zdGFsbGVyIGV4aXQgY29kZTogJFVSQyIKdGFpbCAtMTIgIiRURVNU
>> "!B64TMP!" echo Uk9PVC91bmluc3RhbGwubG9nIgplY2hvICItLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LSIKaWYgWyAhIC1kICIkU0tJTExfRElSIiBdOyB0aGVuCiAgZWNobyAiW09LXSB1bmluc3RhbGxl
>> "!B64TMP!" echo ciByZW1vdmVkIHRoZSBza2lsbCBkaXIiCmVsc2UKICBlY2hvICJbRkFJTF0gc2tpbGwgZGlyIHN0
>> "!B64TMP!" echo aWxsIGV4aXN0cyBhZnRlciB1bmluc3RhbGwiCiAgUEFTUz0wCmZpCmlmIFsgLWYgIiRUR1RfRElS
>> "!B64TMP!" echo Ly5lbnYiIF0gJiYgWyAtZCAiJFRHVF9ESVIvbG9jYWwtd2ViLXNlYXJjaCIgXTsgdGhlbgogIGVj
>> "!B64TMP!" echo aG8gIltPS10gdW5pbnN0YWxsZXIga2VwdCB0aGUgaW5zdGFsbCBmb2xkZXIgKGFzIGFuc3dlcmVk
>> "!B64TMP!" echo KSIKZWxzZQogIGVjaG8gIltGQUlMXSB1bmluc3RhbGxlciBkZWxldGVkIHRoZSBpbnN0YWxsIGZv
>> "!B64TMP!" echo bGRlciBkZXNwaXRlICduJyIKICBQQVNTPTAKZmkKCmVjaG8KaWYgWyAiJFBBU1MiID0gMSBdOyB0
>> "!B64TMP!" echo aGVuCiAgZWNobyAiPT09PT09PT09PT09PT09PT09PT09PT09ICBBTEwgVEVTVFMgUEFTU0VEICA9
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT0iCiAgZXhpdCAwCmZpCmVjaG8gIj09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PSAgVEVTVFMgRkFJTEVEICA9PT09PT09PT09PT09PT09PT09PT09PT09PT0iCmV4
>> "!B64TMP!" echo aXQgMQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\e2e_test.sh"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- zip_test.sh ---
set "B64TMP=%TEMP%\LSR1237637422.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFZlcmlmeSBsb2NhbC1zZWFyY2guemlwOiBleHRyYWN0IGl0
>> "!B64TMP!" echo IGludG8gYSBjbGVhbiB0ZW1wIGRpciwgcnVuIHRoZSAuc2gKIyBpbnN0YWxsZXIgRlJPTSB0aGUg
>> "!B64TMP!" echo ZXh0cmFjdGVkIGZvbGRlciAoYWxsIHNvdXJjZXMgcHJlc2VudCksIGFuZCBjaGVjayB0aGUKIyBy
>> "!B64TMP!" echo ZXN1bHQgKGluY2wuIHRoZSBsb2NhbC13ZWItc2VhcmNoIHNraWxsKS4gTmVlZHM6IHVuemlwICsg
>> "!B64TMP!" echo cHl0aG9uMy4KIyBBbnkgcHJlLWV4aXN0aW5nIH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNl
>> "!B64TMP!" echo YXJjaCBpcyBiYWNrZWQgdXAgYW5kIHJlc3RvcmVkLgpzZXQgLXUKClJPT1Q9IiQoY2QgIiQoZGly
>> "!B64TMP!" echo bmFtZSAiJDAiKSIgJiYgcHdkKSIKWklQPSIkUk9PVC9sb2NhbC1zZWFyY2guemlwIgpURVNUUk9P
>> "!B64TMP!" echo VD0iJFJPT1QvLnppcC10ZXN0LSQkIgpTS0lMTF9ESVI9IiRIT01FLy5hZ2VudHMvc2tpbGxzL2xv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2giClNLSUxMX0JBSz0iIgoKUFk9IiQoY29tbWFuZCAtdiBweXRob24zIHx8
>> "!B64TMP!" echo IGNvbW1hbmQgLXYgcHl0aG9uKSIKWyAteiAiJFBZIiBdICYmIHsgZWNobyAiW0VSUk9SXSBweXRo
>> "!B64TMP!" echo b24gcmVxdWlyZWQgZm9yIHRoaXMgdGVzdC4iID4mMjsgZXhpdCAxOyB9CgpjbGVhbnVwKCkgewog
>> "!B64TMP!" echo IHJjPSQ/CiAgcm0gLXJmICIkU0tJTExfRElSIiAyPi9kZXYvbnVsbAogIGlmIFsgLW4gIiRTS0lM
>> "!B64TMP!" echo TF9CQUsiIF0gJiYgWyAtZCAiJFNLSUxMX0JBSyIgXTsgdGhlbgogICAgbXYgIiRTS0lMTF9CQUsi
>> "!B64TMP!" echo ICIkU0tJTExfRElSIiAyPi9kZXYvbnVsbAogIGZpCiAgaWYgWyAiJHJjIiA9IDAgXTsgdGhlbiBy
>> "!B64TMP!" echo bSAtcmYgIiRURVNUUk9PVCI7IGZpCn0KdHJhcCBjbGVhbnVwIEVYSVQKClsgLWYgIiRaSVAiIF0g
>> "!B64TMP!" echo fHwgeyBlY2hvICJbRVJST1JdICRaSVAgbm90IGZvdW5kIC0gcnVuIGJ1aWxkLnNoIGZpcnN0LiIg
>> "!B64TMP!" echo PiYyOyBleGl0IDE7IH0KY29tbWFuZCAtdiB1bnppcCA+L2Rldi9udWxsIDI+JjEgfHwgeyBlY2hv
>> "!B64TMP!" echo ICJbRVJST1JdIHVuemlwIG5vdCBmb3VuZC4iID4mMjsgZXhpdCAxOyB9Cgpta2RpciAtcCAiJFRF
>> "!B64TMP!" echo U1RST09UIgpjZCAiJFRFU1RST09UIgp1bnppcCAtcSAiJFpJUCIKZWNobyAiRXh0cmFjdGVkIHpp
>> "!B64TMP!" echo cCBjb250ZW50czoiCmZpbmQgbG9jYWwtc2VhcmNoIC10eXBlIGYgfCBzb3J0CmVjaG8KCiMgQmFj
>> "!B64TMP!" echo ayB1cCBhbnkgcmVhbCBza2lsbCBpbnN0YWxsIHNvIHRoZSB0ZXN0IGNhbiBuZXZlciBkZXN0cm95
>> "!B64TMP!" echo IGl0LgppZiBbIC1kICIkU0tJTExfRElSIiBdOyB0aGVuCiAgU0tJTExfQkFLPSIkVEVTVFJPT1Qv
>> "!B64TMP!" echo c2tpbGwtYmFja3VwIgogIG12ICIkU0tJTExfRElSIiAiJFNLSUxMX0JBSyIKZmkKCiMgLS0tIG1v
>> "!B64TMP!" echo Y2sgZG9ja2VyIHNvIHRoZSBpbnN0YWxsZXIncyBjaGVja3MgcGFzcyAtLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tCk1PQ0tCSU49IiRURVNUUk9PVC9iaW4iCm1rZGlyIC1wICIkTU9DS0JJTiIK
>> "!B64TMP!" echo Y2F0ID4gIiRNT0NLQklOL2RvY2tlciIgPDwnTU9DSycKIyEvdXNyL2Jpbi9lbnYgYmFzaApjYXNl
>> "!B64TMP!" echo ICIkMSIgaW4KICBpbmZvKSAgZXhpdCAwIDs7CiAgY29tcG9zZSkKICAgIGNhc2UgIiQyIiBpbgog
>> "!B64TMP!" echo ICAgICB2ZXJzaW9uKSBlY2hvICJEb2NrZXIgQ29tcG9zZSB2Mi4wLjAtdGVzdCI7IGV4aXQgMCA7
>> "!B64TMP!" echo OwogICAgICBwdWxsfHVwKSBlY2hvICJbbW9ja10gb2siOyBleGl0IDAgOzsKICAgICAgKikgZXhp
>> "!B64TMP!" echo dCAwIDs7CiAgICBlc2FjIDs7CiAgKikgZXhpdCAwIDs7CmVzYWMKTU9DSwpjaG1vZCAreCAiJE1P
>> "!B64TMP!" echo Q0tCSU4vZG9ja2VyIgpleHBvcnQgUEFUSD0iJE1PQ0tCSU46JFBBVEgiCgojIC0tLSBydW4gdGhl
>> "!B64TMP!" echo IGluc3RhbGxlciBmcm9tIHRoZSBleHRyYWN0ZWQgZm9sZGVyIChmdWxsIHNvdXJjZSBwcmVzZW50
>> "!B64TMP!" echo KSAtLS0tLS0KIyBhbnN3ZXJzOiB0YXJnZXQsIHNlYXJ4bmcgcG9ydCwgZmlyZWNyYXdsIHBvcnQs
>> "!B64TMP!" echo IExMTT8gLT4gbiwKIyAgICAgICAgICBGaXJlY3Jhd2wgYWNjb3VudD8gLT4gbiAoY29yZS1vbmx5
>> "!B64TMP!" echo IGRlZmF1bHQpLCBjb25maXJtIC0+IHkKVEdUPSIkVEVTVFJPT1QvaW5zdGFsbGVkIgpwcmludGYg
>> "!B64TMP!" echo JyVzXG4lc1xuJXNcbiVzXG4lc1xuJXNcbicgIiRUR1QiICIiICIiICJuIiAibiIgInkiIFwKICB8
>> "!B64TMP!" echo ICIkVEVTVFJPT1QvbG9jYWwtc2VhcmNoL2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoIiA+ICIkVEVT
>> "!B64TMP!" echo VFJPT1QvaW5zdGFsbC5sb2ciIDI+JjEKUkM9JD8KZWNobyAiSW5zdGFsbGVyIGV4aXQgY29kZTog
>> "!B64TMP!" echo JFJDIgp0YWlsIC0xMCAiJFRFU1RST09UL2luc3RhbGwubG9nIgplY2hvICI9PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0iCgojIC0tLSB2ZXJpZnkgdGhlIGluc3RhbGwg
>> "!B64TMP!" echo Zm9sZGVyIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KUEFT
>> "!B64TMP!" echo Uz0xCmZvciBmIGluIGRvY2tlci1jb21wb3NlLnltbCAuZW52LmV4YW1wbGUgLmVudiBSRUFETUUu
>> "!B64TMP!" echo bWQgTElDRU5TRSAuZ2l0aWdub3JlIC5naXRhdHRyaWJ1dGVzIFwKICAgICAgICAgY29uZmlnL3Nl
>> "!B64TMP!" echo YXJ4bmcvc2V0dGluZ3MueW1sIFwKICAgICAgICAgUnVuLmJhdCBTdG9wLmJhdCBVcGRhdGUuYmF0
>> "!B64TMP!" echo IFVuaW5zdGFsbC5iYXQgXAogICAgICAgICBydW4uc2ggc3RvcC5zaCB1cGRhdGUuc2ggdW5pbnN0
>> "!B64TMP!" echo YWxsLnNoIFwKICAgICAgICAgbG9jYWwtd2ViLXNlYXJjaC9TS0lMTC5tZCBcCiAgICAgICAgIGxv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9jb25maWcucHkgbG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRz
>> "!B64TMP!" echo L2Vuc3VyZV9zdGFjay5weSBcCiAgICAgICAgIGxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJf
>> "!B64TMP!" echo c2VhcmNoLnB5IGxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfc2NyYXBlLnB5IFwKICAgICAg
>> "!B64TMP!" echo ICAgaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoOyBkbwog
>> "!B64TMP!" echo IGlmIFsgLXMgIiRUR1QvJGYiIF07IHRoZW4KICAgIGVjaG8gIiAgW09LXSAkZiIKICBlbHNlCiAg
>> "!B64TMP!" echo ICBlY2hvICIgIFtGQUlMXSAkZiAobWlzc2luZy9lbXB0eSkiOyBQQVNTPTAKICBmaQpkb25lCgpp
>> "!B64TMP!" echo ZiBncmVwIC1xICdfX1NFQVJYTkdfU0VDUkVUX1BMQUNFSE9MREVSX18nICIkVEdUL2NvbmZpZy9z
>> "!B64TMP!" echo ZWFyeG5nL3NldHRpbmdzLnltbCI7IHRoZW4KICBlY2hvICJbRkFJTF0gc2V0dGluZ3MueW1sIHN0
>> "!B64TMP!" echo aWxsIGhhcyBwbGFjZWhvbGRlciI7IFBBU1M9MAplbHNlCiAgZWNobyAiW09LXSBzZXR0aW5ncy55
>> "!B64TMP!" echo bWwgc2VjcmV0IGluamVjdGVkIgpmaQoKIyBjb3JlLW9ubHkgZGVmYXVsdDogbm8gYWNjb3VudC1n
>> "!B64TMP!" echo YXRlZCB0b29scywgY29yZSBTS0lMTC5tZCwgbm8gbGVha2VkIHZhcmlhbnQKaWYgWyAtZSAiJFRH
>> "!B64TMP!" echo VC9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2FnZW50LnB5IiBdIFwKICAgfHwgWyAtZSAi
>> "!B64TMP!" echo JFRHVC9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfY3JlYXRlLnB5IiBdIFwK
>> "!B64TMP!" echo ICAgfHwgWyAtZSAiJFRHVC9sb2NhbC13ZWItc2VhcmNoL1NLSUxMLWNvcmUubWQiIF07IHRoZW4K
>> "!B64TMP!" echo ICBlY2hvICJbRkFJTF0gYWNjb3VudC1nYXRlZCB0b29scyAob3IgU0tJTEwtY29yZS5tZCkgaW5z
>> "!B64TMP!" echo dGFsbGVkIGluIGNvcmUgbW9kZSI7IFBBU1M9MAplbHNlCiAgZWNobyAiW09LXSBjb3JlLW9ubHkg
>> "!B64TMP!" echo c2tpbGw6IGFjY291bnQtZ2F0ZWQgdG9vbHMgc2tpcHBlZCwgbm8gU0tJTEwtY29yZS5tZCIKZmkK
>> "!B64TMP!" echo aWYgZ3JlcCAtcSAiNSB0b29sczogc2VhcmNoLCBzY3JhcGUsIG1hcCwgY3Jhd2wsIGNyYXdsIHN0
>> "!B64TMP!" echo YXR1cyIgIiRUR1QvbG9jYWwtd2ViLXNlYXJjaC9TS0lMTC5tZCI7IHRoZW4KICBlY2hvICJbT0td
>> "!B64TMP!" echo IFNLSUxMLm1kIGlzIHRoZSBjb3JlLW9ubHkgdmFyaWFudCIKZWxzZQogIGVjaG8gIltGQUlMXSBT
>> "!B64TMP!" echo S0lMTC5tZCBpcyBub3QgdGhlIGNvcmUtb25seSB2YXJpYW50IjsgUEFTUz0wCmZpCgppZiBbICIk
>> "!B64TMP!" echo KGNhdCAiJFNLSUxMX0RJUi9pbnN0YWxsLWRpci50eHQiIDI+L2Rldi9udWxsKSIgPSAiJFRHVCIg
>> "!B64TMP!" echo XTsgdGhlbgogIGVjaG8gIltPS10gc2tpbGwgaW5zdGFsbGVkIHdpdGggY29ycmVjdCBpbnN0YWxs
>> "!B64TMP!" echo LWRpci50eHQgaGludCIKZWxzZQogIGVjaG8gIltGQUlMXSBza2lsbCBpbnN0YWxsLWRpci50eHQg
>> "!B64TMP!" echo d3Jvbmc6ICQoY2F0ICIkU0tJTExfRElSL2luc3RhbGwtZGlyLnR4dCIgMj4vZGV2L251bGwpIgog
>> "!B64TMP!" echo IFBBU1M9MApmaQoKY21wIC1zICIkVEdUL2luc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCIgIiRST09U
>> "!B64TMP!" echo L2xvY2FsLXNlYXJjaC9pbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQiIFwKICAmJiBlY2hvICJbT0td
>> "!B64TMP!" echo IC5iYXQgcmVwcm9kdWNlZCBieXRlLWlkZW50aWNhbCIgXAogIHx8IHsgZWNobyAiW0ZBSUxdIC5i
>> "!B64TMP!" echo YXQgZGlmZmVycyI7IFBBU1M9MDsgfQoKZWNobwppZiBbICIkUEFTUyIgPSAxIF0gJiYgWyAiJFJD
>> "!B64TMP!" echo IiA9IDAgXTsgdGhlbgogIGVjaG8gIj09PT09PT09IEZVTEwtWklQIEVYVFJBQ1RJT04gVEVTVDog
>> "!B64TMP!" echo UEFTU0VEID09PT09PT09IgogIGV4aXQgMApmaQplY2hvICI9PT09PT09PSBGVUxMLVpJUCBFWFRS
>> "!B64TMP!" echo QUNUSU9OIFRFU1Q6IEZBSUxFRCA9PT09PT09PSIKZXhpdCAxCg==
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
>> "!B64TMP!" echo LnNoIHN0b3Auc2ggdXBkYXRlLnNoIHVuaW5zdGFsbC5zaCBcCiAgICAgICAgIGxvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gvU0tJTEwubWQgbG9jYWwtd2ViLXNlYXJjaC9TS0lMTC1jb3JlLm1kIFwKICAgICAgICAg
>> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL2NvbmZpZy5weSBsb2NhbC13ZWItc2VhcmNoL3Njcmlw
>> "!B64TMP!" echo dHMvZW5zdXJlX3N0YWNrLnB5IFwKICAgICAgICAgbG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dl
>> "!B64TMP!" echo Yl9zZWFyY2gucHkgbG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9zY3JhcGUucHk7IGRvCiAg
>> "!B64TMP!" echo Y2hlY2tfZmlsZSAibG9jYWwtc2VhcmNoLyRmIgpkb25lCiMgTk9URTogbG9jYWwtc2VhcmNoL2lu
>> "!B64TMP!" echo c3RhbGwtbG9jYWwtc2VhcmNoLiogYXJlIGludGVudGlvbmFsbHkgTk9UIHVucGFja2VkIGJ5CiMg
>> "!B64TMP!" echo dGhlIHBhY2tlciAodGhleSBhcmUgZ2VuZXJhdGVkIGFydGlmYWN0cykgLSB0aGV5IGFyZSB2ZXJp
>> "!B64TMP!" echo ZmllZCBpbiBzdGVwIDUuCgpmb3IgZiBpbiBnZW5faW5zdGFsbGVycy5weSBnZW5fcmlnLnB5IHRl
>> "!B64TMP!" echo c3RfYjY0LnB5IHRlc3RfaGVyZWRvY3MucHkgdGVzdF9yaWcucHkgXAogICAgICAgICBlMmVfdGVz
>> "!B64TMP!" echo dC5zaCB6aXBfdGVzdC5zaCBidWlsZC5zaCBidWlsZC5iYXQgQlVJTEQubWQgXAogICAgICAgICBs
>> "!B64TMP!" echo b2NhbC1zZWFyY2gtcmlnLmJhdCBsb2NhbC1zZWFyY2gtcmlnLnNoOyBkbwogIGNoZWNrX2ZpbGUg
>> "!B64TMP!" echo IiRmIgpkb25lCgojIC5iYXQgZmlsZXMgdW5wYWNrZWQgYnkgdGhlIC5zaCBwYWNrZXIgbXVzdCBo
>> "!B64TMP!" echo YXZlIENSTEYgZW5kaW5ncwpmb3IgZiBpbiBsb2NhbC1zZWFyY2gvUnVuLmJhdCBsb2NhbC1zZWFy
>> "!B64TMP!" echo Y2gvVXBkYXRlLmJhdCBsb2NhbC1zZWFyY2gtcmlnLmJhdCBidWlsZC5iYXQ7IGRvCiAgaWYgZ3Jl
>> "!B64TMP!" echo cCAtcSAkJ1xyJyAiJFRFU1RST09UL3JpZy8kZiIgMj4vZGV2L251bGw7IHRoZW4KICAgIGVjaG8g
>> "!B64TMP!" echo IiAgW09LXSAgICRmIGhhcyBDUkxGIgogIGVsc2UKICAgIGVjaG8gIiAgW0ZBSUxdICRmIGxhY2tz
>> "!B64TMP!" echo IENSTEYiOyBQQVNTPTAKICBmaQpkb25lCmVjaG8KCmVjaG8gIj09PSA0LiBTRUxGLUhPU1RJTkc6
>> "!B64TMP!" echo IHJlZ2VuZXJhdGUgcGFja2VycyBpbnNpZGUgdW5wYWNrZWQgcmlnID09PSIKaWYgKGNkICIkVEVT
>> "!B64TMP!" echo VFJPT1QvcmlnIiAmJiBweXRob24zIGdlbl9yaWcucHkpOyB0aGVuCiAgaWYgY21wIC1zICIkUk9P
>> "!B64TMP!" echo VC9sb2NhbC1zZWFyY2gtcmlnLnNoIiAiJFRFU1RST09UL3JpZy9sb2NhbC1zZWFyY2gtcmlnLnNo
>> "!B64TMP!" echo IjsgdGhlbgogICAgZWNobyAiICBbT0tdIGxvY2FsLXNlYXJjaC1yaWcuc2ggcmVnZW5lcmF0ZWQg
>> "!B64TMP!" echo QllURS1JREVOVElDQUwiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gbG9jYWwtc2VhcmNoLXJp
>> "!B64TMP!" echo Zy5zaCBkaWZmZXJzIGFmdGVyIHJlZ2VuZXJhdGlvbiI7IFBBU1M9MAogIGZpCiAgaWYgY21wIC1z
>> "!B64TMP!" echo ICIkUk9PVC9sb2NhbC1zZWFyY2gtcmlnLmJhdCIgIiRURVNUUk9PVC9yaWcvbG9jYWwtc2VhcmNo
>> "!B64TMP!" echo LXJpZy5iYXQiOyB0aGVuCiAgICBlY2hvICIgIFtPS10gbG9jYWwtc2VhcmNoLXJpZy5iYXQgcmVn
>> "!B64TMP!" echo ZW5lcmF0ZWQgQllURS1JREVOVElDQUwiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gbG9jYWwt
>> "!B64TMP!" echo c2VhcmNoLXJpZy5iYXQgZGlmZmVycyBhZnRlciByZWdlbmVyYXRpb24iOyBQQVNTPTAKICBmaQpl
>> "!B64TMP!" echo bHNlCiAgZWNobyAiICBbRkFJTF0gZ2VuX3JpZy5weSBmYWlsZWQgaW4gdW5wYWNrZWQgcmlnIjsg
>> "!B64TMP!" echo UEFTUz0wCmZpCmVjaG8KCmVjaG8gIj09PSA1LiByZWdlbmVyYXRlIGluc3RhbGxlcnMgaW5zaWRl
>> "!B64TMP!" echo IHVucGFja2VkIHJpZyA9PT0iCmlmIChjZCAiJFRFU1RST09UL3JpZyIgJiYgcHl0aG9uMyBnZW5f
>> "!B64TMP!" echo aW5zdGFsbGVycy5weSk7IHRoZW4KICBpZiBjbXAgLXMgIiRST09UL2xvY2FsLXNlYXJjaC9pbnN0
>> "!B64TMP!" echo YWxsLWxvY2FsLXNlYXJjaC5zaCIgIiRURVNUUk9PVC9yaWcvbG9jYWwtc2VhcmNoL2luc3RhbGwt
>> "!B64TMP!" echo bG9jYWwtc2VhcmNoLnNoIjsgdGhlbgogICAgZWNobyAiICBbT0tdIGluc3RhbGwtbG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoLnNoIHJlZ2VuZXJhdGVkIEJZVEUtSURFTlRJQ0FMIgogIGVsc2UKICAgIGVjaG8gIiAgW0ZB
>> "!B64TMP!" echo SUxdIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIGRpZmZlcnMiOyBQQVNTPTAKICBmaQogIGlmIGNt
>> "!B64TMP!" echo cCAtcyAiJFJPT1QvbG9jYWwtc2VhcmNoL2luc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCIgIiRURVNU
>> "!B64TMP!" echo Uk9PVC9yaWcvbG9jYWwtc2VhcmNoL2luc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCI7IHRoZW4KICAg
>> "!B64TMP!" echo IGVjaG8gIiAgW09LXSBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQgcmVnZW5lcmF0ZWQgQllURS1J
>> "!B64TMP!" echo REVOVElDQUwiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gaW5zdGFsbC1sb2NhbC1zZWFyY2gu
>> "!B64TMP!" echo YmF0IGRpZmZlcnMiOyBQQVNTPTAKICBmaQplbHNlCiAgZWNobyAiICBbRkFJTF0gZ2VuX2luc3Rh
>> "!B64TMP!" echo bGxlcnMucHkgZmFpbGVkIGluIHVucGFja2VkIHJpZyI7IFBBU1M9MApmaQplY2hvCgplY2hvICI9
>> "!B64TMP!" echo PT0gNi4gdmVyaWZ5IHRlc3Qgc3VpdGUgcGFzc2VzIGluc2lkZSB0aGUgdW5wYWNrZWQgcmlnID09
>> "!B64TMP!" echo PSIKaWYgKGNkICIkVEVTVFJPT1QvcmlnIiAmJiBweXRob24zIHRlc3RfcmlnLnB5ID4gL2Rldi9u
>> "!B64TMP!" echo dWxsIDI+JjEpOyB0aGVuCiAgZWNobyAiICBbT0tdIHRlc3RfcmlnLnB5IHBhc3NlcyBpbiB1bnBh
>> "!B64TMP!" echo Y2tlZCByaWciCmVsc2UKICBlY2hvICIgIFtGQUlMXSB0ZXN0X3JpZy5weSBmYWlscyBpbiB1bnBh
>> "!B64TMP!" echo Y2tlZCByaWciOyBQQVNTPTAKZmkKCmVjaG8KaWYgWyAiJFBBU1MiID0gMSBdOyB0aGVuCiAgZWNo
>> "!B64TMP!" echo byAiPT09PT09PT09PT09PT09PT0gIFNFTEYtSE9TVElORyBURVNUOiBQQVNTRUQgID09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09IgogIGV4aXQgMApmaQplY2hvICI9PT09PT09PT09PT09PT09PSAgU0VMRi1IT1NU
>> "!B64TMP!" echo SU5HIFRFU1Q6IEZBSUxFRCAgPT09PT09PT09PT09PT09PT0iCmV4aXQgMQo=
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
>> "!B64TMP!" echo cy5weSDigJQgZG8gbm90IGVkaXQKICAuLi4gICAgICAgICAgICAgICAgICAgICAgICAgIOKGkCA0
>> "!B64TMP!" echo NCBzb3VyY2UgZmlsZXMgKGNvbXBvc2UsIHNjcmlwdHMsIHNraWxsLCBkb2NzKQpnZW5faW5zdGFs
>> "!B64TMP!" echo bGVycy5weSAgICAgICAgICAgICAgcmVhZHMgbG9jYWwtc2VhcmNoLyDihpIgd3JpdGVzIHRoZSB0
>> "!B64TMP!" echo d28gaW5zdGFsbGVycwpnZW5fcmlnLnB5ICAgICAgICAgICAgICAgICAgICAgcmVhZHMgbG9jYWwt
>> "!B64TMP!" echo c2VhcmNoLyArIHRoaXMgcmlnIOKGkiB3cml0ZXMgdGhlIHR3byBwYWNrZXJzCmV4dHJhY3QtZW1i
>> "!B64TMP!" echo ZWRkZWQucHkgICAgICAgICAgICBwdWxsIGFsbCBlbWJlZGRlZCBmaWxlcyBvdXQgb2YgYW55IHNp
>> "!B64TMP!" echo bmdsZSAuc2ggYXJ0aWZhY3QKdGVzdF9iNjQucHkgICAgICAgICAgICAgICAgICAgIGV2ZXJ5IGZp
>> "!B64TMP!" echo bGUgZW1iZWRkZWQgaW4gdGhlIC5iYXQgaW5zdGFsbGVyIHJvdW5kLXRyaXBzCnRlc3RfaGVyZWRv
>> "!B64TMP!" echo Y3MucHkgICAgICAgICAgICAgICBldmVyeSBmaWxlIGVtYmVkZGVkIGluIHRoZSAuc2ggaW5zdGFs
>> "!B64TMP!" echo bGVyIG1hdGNoZXMKdGVzdF9yaWcucHkgICAgICAgICAgICAgICAgICAgIGJvdGggcmlnIHBhY2tl
>> "!B64TMP!" echo cnMgZW1iZWQgdGhlIGN1cnJlbnQgZmlsZXMgZXhhY3RseQplMmVfdGVzdC5zaCAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgaW5zdGFsbCDihpIgc2tpbGwg4oaSIHNlbGYtaGVhbCDihpIgYWNjb3VudCBtb2Rl
>> "!B64TMP!" echo IOKGkiBkb2NrZXIgYXV0by1zdGFydCDihpIgdW5pbnN0YWxsIChtb2NrZWQgZG9ja2VyICsgZmFr
>> "!B64TMP!" echo ZSBzdGFjaykKemlwX3Rlc3Quc2ggICAgICAgICAgICAgICAgICAgIGV4dHJhY3QgbG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoLnppcCBhbmQgaW5zdGFsbCBmcm9tIGl0CnNlbGZob3N0X3Rlc3Quc2ggICAgICAgICAgICAg
>> "!B64TMP!" echo ICB1bnBhY2sgYSBwYWNrZXIgYWxvbmUg4oaSIHJlZ2VuZXJhdGUg4oaSIGJ5dGUtY29tcGFyZQpi
>> "!B64TMP!" echo dWlsZC5zaCAvIGJ1aWxkLmJhdCAgICAgICAgICAgcmVnZW5lcmF0ZSBldmVyeXRoaW5nICsgcnVu
>> "!B64TMP!" echo IGFsbCB0ZXN0cyArIGJ1aWxkIHRoZSB6aXAKQlVJTEQubWQgICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo IHRoaXMgZmlsZQpgYGAKCiMjIFF1aWNrIHN0YXJ0CgpMaW51eCAvIG1hY09TIC8gR2l0IEJhc2g6
>> "!B64TMP!" echo CgpgYGBiYXNoCmJhc2ggYnVpbGQuc2gKYGBgCgpXaW5kb3dzOgoKYGBgYmF0CmJ1aWxkLmJhdApg
>> "!B64TMP!" echo YGAKCmBidWlsZC5zaGAgcnVucyB0aGUgZnVsbCBwaXBlbGluZTogZ2VuZXJhdGUgaW5zdGFsbGVy
>> "!B64TMP!" echo cyDihpIgdmVyaWZ5IGVtYmVkcyDihpIKZTJlIGluc3RhbGwgdGVzdCDihpIgcmVnZW5lcmF0ZSB0
>> "!B64TMP!" echo aGUgcGFja2VycyDihpIgdmVyaWZ5IHBhY2tlcnMg4oaSIHNlbGYtaG9zdGluZwp0ZXN0ICh1bnBh
>> "!B64TMP!" echo Y2sgYSBwYWNrZXIgYWxvbmUsIHJlZ2VuZXJhdGUsIGJ5dGUtY29tcGFyZSkg4oaSIGJ1aWxkICsg
>> "!B64TMP!" echo cmUtdGVzdAp0aGUgemlwLiBgYnVpbGQuYmF0YCBkb2VzIHRoZSBzYW1lIG1pbnVzIHRoZSBiYXNo
>> "!B64TMP!" echo LW9ubHkgZTJlL3NlbGZob3N0IHRlc3RzCihydW4gYGJhc2ggZTJlX3Rlc3Quc2hgIC8gYGJhc2gg
>> "!B64TMP!" echo c2VsZmhvc3RfdGVzdC5zaGAgZnJvbSBHaXQgQmFzaCBpZiB5b3Ugd2FudAp0aGVtIG9uIFdpbmRv
>> "!B64TMP!" echo d3MpLgoKIyMgV29ya2Zsb3cgYWZ0ZXIgZWRpdGluZyBhbnl0aGluZwoKMS4gRWRpdCBhbnkgZmls
>> "!B64TMP!" echo ZSB1bmRlciBgbG9jYWwtc2VhcmNoL2AgKG9yIGFueSByaWcgc2NyaXB0KS4KMi4gUnVuIGBiYXNo
>> "!B64TMP!" echo IGJ1aWxkLnNoYCAob3IgYGJ1aWxkLmJhdGApLgozLiBBcnRpZmFjdHM6CiAgIC0gYGxvY2FsLXNl
>> "!B64TMP!" echo YXJjaC9pbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXRgIC8gYC5zaGAg4oCUIHRoZSBzZWxmLWNvbnRh
>> "!B64TMP!" echo aW5lZCBpbnN0YWxsZXJzCiAgIC0gYGxvY2FsLXNlYXJjaC1yaWcuYmF0YCAvIGBsb2NhbC1zZWFy
>> "!B64TMP!" echo Y2gtcmlnLnNoYCDigJQgdGhlIHNlbGYtY29udGFpbmVkIGRldi1yaWcgcGFja2VycwogICAtIGBs
>> "!B64TMP!" echo b2NhbC1zZWFyY2guemlwYCDigJQgcmVwbyBzbmFwc2hvdCBmb3IgR2l0SHViCgojIyBUaGUgcGFj
>> "!B64TMP!" echo a2VycwoKYGxvY2FsLXNlYXJjaC1yaWcuYmF0YCBhbmQgYGxvY2FsLXNlYXJjaC1yaWcuc2hgIGVt
>> "!B64TMP!" echo YmVkIHRoZSAqKmVudGlyZSByaWcqKiDigJQKdGhlIGxvY2FsLXNlYXJjaCBzb3VyY2UgdHJlZSwg
>> "!B64TMP!" echo ZXZlcnkgZ2VuZXJhdG9yL3Rlc3QvYnVpbGQgc2NyaXB0LCB0aGlzIGZpbGUsCmFuZCAoaW4gdGhl
>> "!B64TMP!" echo IGAuc2hgKSB0aGUgYC5iYXRgIHBhY2tlciBpdHNlbGYuIFRoYXQgbWVhbnMgKiplaXRoZXIgb25l
>> "!B64TMP!" echo IGZpbGUKYWxvbmUqKiByZXByb2R1Y2VzIHRoZSBjb21wbGV0ZSBkZXYgZW52aXJvbm1lbnQsIGlu
>> "!B64TMP!" echo Y2x1ZGluZyBib3RoIHBhY2tlcnM6CgpgYGBiYXNoCmNobW9kICt4IGxvY2FsLXNlYXJjaC1yaWcu
>> "!B64TMP!" echo c2gKLi9sb2NhbC1zZWFyY2gtcmlnLnNoICAgICAgICAjIGFza3MgZm9yIGEgZm9sZGVyLCB1bnBh
>> "!B64TMP!" echo Y2tzLCBvcHRpb25hbGx5IGJ1aWxkcwpgYGAKClRoZXkgYXJlICoqc2VsZi1ob3N0aW5nKio6IGFm
>> "!B64TMP!" echo dGVyIHVucGFja2luZywgYHB5dGhvbjMgZ2VuX3JpZy5weWAgcmVnZW5lcmF0ZXMKYm90aCBwYWNr
>> "!B64TMP!" echo ZXJzIGJ5dGUtZm9yLWJ5dGUgKHZlcmlmaWVkIGJ5IHRoZSBidWlsZCBwaXBlbGluZSBhbmQgYnkK
>> "!B64TMP!" echo YHNlbGZob3N0X3Rlc3Quc2hgLCB3aGljaCB1bnBhY2tzIGEgcGFja2VyIGludG8gYSBjbGVhbiBm
>> "!B64TMP!" echo b2xkZXIgYW5kIHByb3ZlcwpyZWdlbmVyYXRpb24gaXMgZXhhY3QpLiBUaGUgZ2VuZXJhdGVkIGlu
>> "!B64TMP!" echo c3RhbGxlcnMgdGhlbXNlbHZlcyBhcmUgTk9UIGVtYmVkZGVkIOKAlApydW4gdGhlIGJ1aWxkICh0
>> "!B64TMP!" echo aGUgcGFja2VyIG9mZmVycykgb3IgYHB5dGhvbjMgZ2VuX2luc3RhbGxlcnMucHlgIHRvIGNyZWF0
>> "!B64TMP!" echo ZQp0aGVtIGZyZXNoLgoKIyMgTWFudWFsIGNvbW1hbmRzCgpgYGBiYXNoCnB5dGhvbjMgZ2VuX2lu
>> "!B64TMP!" echo c3RhbGxlcnMucHkgICAgIyByZWJ1aWxkIGp1c3QgdGhlIHR3byBpbnN0YWxsZXJzCnB5dGhvbjMg
>> "!B64TMP!" echo Z2VuX3JpZy5weSAgICAgICAgICAgIyByZWJ1aWxkIGp1c3QgdGhlIHR3byBwYWNrZXJzCnB5dGhv
>> "!B64TMP!" echo bjMgdGVzdF9iNjQucHkgICAgICAgICAgIyB2ZXJpZnkgLmJhdCBpbnN0YWxsZXIgZW1iZWRzCnB5
>> "!B64TMP!" echo dGhvbjMgdGVzdF9oZXJlZG9jcy5weSAgICAgIyB2ZXJpZnkgLnNoIGluc3RhbGxlciBlbWJlZHMK
>> "!B64TMP!" echo cHl0aG9uMyB0ZXN0X3JpZy5weSAgICAgICAgICAjIHZlcmlmeSBwYWNrZXIgZW1iZWRzCmJhc2gg
>> "!B64TMP!" echo ZTJlX3Rlc3Quc2ggICAgICAgICAgICAgIyBpbnN0YWxsL3VuaW5zdGFsbCArIHNlbGYtaGVhbCB0
>> "!B64TMP!" echo ZXN0IChtb2NrZWQgZG9ja2VyKQpiYXNoIHppcF90ZXN0LnNoICAgICAgICAgICAgICMgemlwIGV4
>> "!B64TMP!" echo dHJhY3Rpb24gdGVzdCAobmVlZHMgdW56aXApCmJhc2ggc2VsZmhvc3RfdGVzdC5zaCAgICAgICAg
>> "!B64TMP!" echo IyB1bnBhY2sgYSBwYWNrZXIgYWxvbmUg4oaSIHJlZ2VuZXJhdGUg4oaSIGJ5dGUtY29tcGFyZQpg
>> "!B64TMP!" echo YGAKCiMjIFNpbmdsZS1maWxlIHJlY292ZXJ5IChubyBEb2NrZXIgbmVlZGVkKQoKTG9zdCBldmVy
>> "!B64TMP!" echo eXRoaW5nIGV4Y2VwdCBvbmUgYC5zaGAgYXJ0aWZhY3Q/IGBleHRyYWN0LWVtYmVkZGVkLnB5YCBw
>> "!B64TMP!" echo dWxscyBldmVyeQplbWJlZGRlZCBmaWxlIG91dCBvZiBpdCDigJQgaXQgb25seSBwYXJzZXMgdGhl
>> "!B64TMP!" echo IHF1b3RlZCBoZXJlZG9jcywgbm90aGluZyBpcwpleGVjdXRlZDoKCmBgYGJhc2gKIyBmcm9tIHRo
>> "!B64TMP!" echo ZSByaWcgcGFja2VyOiByZWNvdmVycyB0aGUgQ09NUExFVEUgcmlnICg1NyBmaWxlcykKcHl0aG9u
>> "!B64TMP!" echo MyBleHRyYWN0LWVtYmVkZGVkLnB5IGxvY2FsLXNlYXJjaC1yaWcuc2ggcmlnCiMgdGhlbiByZWdl
>> "!B64TMP!" echo bmVyYXRlIGV2ZXJ5dGhpbmc6CmNkIHJpZyAmJiBweXRob24zIGdlbl9pbnN0YWxsZXJzLnB5ICYm
>> "!B64TMP!" echo IHB5dGhvbjMgZ2VuX3JpZy5weQoKIyBmcm9tIHRoZSBpbnN0YWxsZXI6IHJlY292ZXJzIHRoZSBs
>> "!B64TMP!" echo b2NhbC1zZWFyY2gvIHNvdXJjZXMgKyB0aGUgLmJhdCBpbnN0YWxsZXIKcHl0aG9uMyBleHRyYWN0
>> "!B64TMP!" echo LWVtYmVkZGVkLnB5IGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIGxvY2FsLXNlYXJjaAojIGFkZCB0
>> "!B64TMP!" echo aGUgcmlnIHNjcmlwdHMgKHZpc2libGUgaW4gdGhlIHJlcG8pIG5leHQgdG8gaXQgYW5kIHJlZ2Vu
>> "!B64TMP!" echo ZXJhdGUuCmBgYAoKVGhlIGAuc2hgIGZpbGUgeW91IGV4dHJhY3RlZCBmcm9tIGlzIG5ldmVyIGVt
>> "!B64TMP!" echo YmVkZGVkIGluIGl0c2VsZiDigJQgY29weSBpdCBvdmVyCm1hbnVhbGx5IGlmIHlvdSB3YW50IGl0
>> "!B64TMP!" echo IGluIHRoZSByZWNvdmVyZWQgdHJlZS4KCiMjIENvbnZlbnRpb25zCgotICoqTGluZSBlbmRpbmdz
>> "!B64TMP!" echo OioqIGAuYmF0YCBzb3VyY2VzIGFyZSBDUkxGOyBgLnNoYCAvIGAucHlgIC8gYC5tZGAgLyBgLnlt
>> "!B64TMP!" echo bGAKICBhcmUgTEYuIFRoZSBgLnNoYCBwYWNrZXIgbm9ybWFsaXplcyB0byBMRiBpbnNpZGUgaXRz
>> "!B64TMP!" echo IGhlcmVkb2NzIGFuZCByZXN0b3JlcwogIENSTEYgZm9yIGV2ZXJ5IGAqLmJhdGAgb24gdW5wYWNr
>> "!B64TMP!" echo ICh2aWEgYXdrLCBzbyBpdCBhbHNvIHdvcmtzIG9uIG1hY09TKS4KLSAqKmJhc2ggMy4yIHNhZmU6
>> "!B64TMP!" echo KiogYWxsIHNoZWxsIHNjcmlwdHMgYXZvaWQgYCR7dmFyLCx9YCwgYHNlZCAtaWAsIGFuZAogIEdO
>> "!B64TMP!" echo VS1vbmx5IHNlZCBlc2NhcGVzLCBzbyB0aGV5IHJ1biBvbiB0aGUgbWFjT1MgZGVmYXVsdCBzaGVs
>> "!B64TMP!" echo bC4gQ2FzZS1mb2xkaW5nCiAgZ29lcyB0aHJvdWdoIHRoZSBgbG93ZXIoKWAgaGVscGVyIChgdHIg
>> "!B64TMP!" echo J1s6dXBwZXI6XScgJ1s6bG93ZXI6XSdgKS4KLSAqKlNhZmUgdGVzdHM6KiogYGUyZV90ZXN0LnNo
>> "!B64TMP!" echo YCBhbmQgYHppcF90ZXN0LnNoYCBiYWNrIHVwIGFuZCByZXN0b3JlCiAgYH4vLmFnZW50cy9za2ls
>> "!B64TMP!" echo bHMvbG9jYWwtd2ViLXNlYXJjaGAgaWYgeW91IGhhdmUgYSByZWFsIGluc3RhbGwg4oCUIHRoZXkg
>> "!B64TMP!" echo bmV2ZXIKICBkZXN0cm95IGl0LiBUZXN0IGZvbGRlcnMgKGAubHMtdGVzdC0qYCwgYC56aXAtdGVz
>> "!B64TMP!" echo dC0qYCkgYXJlIHJlbW92ZWQgb24KICBzdWNjZXNzIGFuZCBrZXB0IG9uIGZhaWx1cmUgZm9yIGRl
>> "!B64TMP!" echo YnVnZ2luZy4KLSAqKk1vY2tlZCBkb2NrZXI6KiogdGhlIGUyZSB0ZXN0cyBwdXQgYSBmYWtlIGBk
>> "!B64TMP!" echo b2NrZXJgIG9uIFBBVEgsIHNvIHRoZXkgcnVuCiAgdGhlIGZ1bGwgaW5zdGFsbCBsb2dpYyB3aXRo
>> "!B64TMP!" echo b3V0IHRvdWNoaW5nIGEgcmVhbCBEb2NrZXIgZGFlbW9uLgo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\BUILD.md"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM Keep a copy of this packer in the target so the rig is complete.
copy /Y "%~f0" "!TARGET!\local-search-rig.bat" >nul 2>&1
echo   Done - 56 files + this packer.

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
