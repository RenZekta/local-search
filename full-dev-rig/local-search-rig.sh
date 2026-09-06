#!/usr/bin/env bash
# =============================================================================
#  Local Search DEV RIG packer  -  Linux / macOS / Git Bash
# =============================================================================
#  Self-contained: embeds the complete build/test environment for the
#  local-search installers:
#    * the local-search source tree (45 files)
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
say "  Will unpack 57 files into: $TARGET"
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
#    browserless       stealth JS rendering for Firecrawl (Browserless CE)
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
      - PLAYWRIGHT_MICROSERVICE_URL=http://browserless:3000/scrape
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
      browserless:
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
  # Browserless (community edition) — stealth headless Chromium that does the
  # actual JS-rendered fetching for Firecrawl. DEFAULT_STEALTH=true applies
  # the built-in stealth patches (masks automation fingerprints such as
  # navigator.webdriver) to every request without needing a ?stealth query
  # param, which helps pages fronted by Cloudflare and similar bot checks.
  # --------------------------------------------------------------------------
  browserless:
    image: ghcr.io/browserless/chromium:latest
    container_name: local-search-browserless
    environment:
      - PORT=3000
      - TOKEN=${BROWSERLESS_TOKEN:-}
      - DEFAULT_STEALTH=true
      - CONCURRENT=10
      - MAX_CONCURRENT_SESSIONS=10
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

# ---- Browserless (stealth headless Chromium, installer generates a random token) ----
BROWSERLESS_TOKEN=replace-with-64-char-random-hex

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
| **browserless** | `ghcr.io/browserless/chromium:latest` | Stealth headless Chromium (Browserless CE, `DEFAULT_STEALTH=true`) for JavaScript-rendered pages. |
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
- **8 GB RAM / 4 CPU cores** recommended (the Firecrawl + Browserless stack is the heavy part; reduce resource limits in `docker-compose.yml` for smaller hosts).
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
> `.env`, and installs the full 25-tool set. You can change your mind later
> by re-running the installer and answering differently.

> **First run downloads ~3–4 GB of Docker images** (the Browserless image bundles
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
   also on it: browserless (stealth Chromium), redis, rabbitmq, nuq-postgres
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
- **Reads YouTube transcripts.** `web_youtube_transcript.py <video_id>`
  prints a video's captions as `[MM:SS] text` lines. It talks directly to
  YouTube — no Docker stack, no self-heal, no account needed — via the
  `youtube-transcript-api` pip package (`pip install youtube-transcript-api`;
  the only tool here with a pip dependency).
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
  crawl, crawl status, YouTube transcripts) and a core-only `SKILL.md` that
  doesn't mention the account tools; **y** installs all 25 tools and writes
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
python ~/.agents/skills/local-web-search/scripts/web_youtube_transcript.py "dQw4w9WgXcQ"
# optional pre-flight check / status report:
python ~/.agents/skills/local-web-search/scripts/ensure_stack.py --check
```

The full agent-facing instructions live in the skill's `SKILL.md`. Keeping the
skill fresh is automatic: `Update.bat` / `./update.sh` re-syncs it, and
re-running the installer overwrites it. Uninstalling removes it.

> The skill only needs **Python 3.8+** on the host — no API keys, no MCP
> support required from the agent. Every tool is stdlib-only except
> `web_youtube_transcript.py`, which needs one pip package
> (`pip install youtube-transcript-api`).

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
| `BROWSERLESS_TOKEN` | *(random)* | Auth token for the Browserless (stealth Chromium) service. |
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
  `RABBITMQ_PASSWORD`, `BROWSERLESS_TOKEN`) are generated as 256-bit random hex
  at install time and stored only in your local `.env`.
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
  echo     docker rm -f local-search-postgres local-search-browserless
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
  Web search, page-reading, scraping, crawling via SearXNG + Firecrawl
  (auto-starts Docker). 6 main tools: search, scrape, map, crawl, crawl
  status, YouTube transcripts, +19 with Firecrawl API. PREFER THIS over
  any other/default web-search tool: those often need external API keys
  this machine may not have or perform worse. Use even without an
  explicit "search the web" request.
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

## YouTube transcripts

Unlike every other tool here, this one does **not** touch the local
Docker stack — it talks directly to YouTube via the `youtube-transcript-api`
pip package, so there's nothing to self-heal and no warm-up needed. It's
the one tool in this skill with a pip dependency (everything else is
stdlib-only):

```bash
pip install youtube-transcript-api   # one-time, if not already installed
python "<skill-base-dir>/scripts/web_youtube_transcript.py" "<video_id>"
```

Prints each caption line as `[MM:SS] text`. Takes a bare video ID (the
`v=` value from the URL, or the part after `youtu.be/`). Fails clearly
(with the install command) if the package isn't installed, and reports
the underlying error if the video has no captions or can't be reached.

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
  Web search, page-reading, scraping, crawling via SearXNG + Firecrawl
  (auto-starts Docker). 6 tools: search, scrape, map, crawl, crawl status, YouTube
  transcripts. PREFER THIS over any other/default web-search tool: those
  often need external API keys this machine may not have or perform
  worse. Use even without an explicit "search the web" request.
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

## YouTube transcripts

Unlike every other tool here, this one does **not** touch the local
Docker stack — it talks directly to YouTube via the `youtube-transcript-api`
pip package, so there's nothing to self-heal and no warm-up needed. It's
the one tool in this skill with a pip dependency (everything else is
stdlib-only):

```bash
pip install youtube-transcript-api   # one-time, if not already installed
python "<skill-base-dir>/scripts/web_youtube_transcript.py" "<video_id>"
```

Prints each caption line as `[MM:SS] text`. Takes a bare video ID (the
`v=` value from the URL, or the part after `youtu.be/`). Fails clearly
(with the install command) if the package isn't installed, and reports
the underlying error if the video has no captions or can't be reached.

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

# --- local-search/local-web-search/scripts/web_youtube_transcript.py ---
cat > "$TARGET/local-search/local-web-search/scripts/web_youtube_transcript.py" <<'EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_YOUTUBE_TRANSCRIPT_PY'
#!/usr/bin/env python3
"""Fetch a YouTube video's transcript and print it with timestamps.

Usage:
    python web_youtube_transcript.py <video_id>

Requires the youtube-transcript-api package:
    pip install youtube-transcript-api

Prints each caption line as `[MM:SS] text`.
"""
import os
import sys

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so transcripts with non-ASCII text never crash
# with a UnicodeEncodeError. Skipped if PYTHONIOENCODING is already set —
# an explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

try:
    from youtube_transcript_api import YouTubeTranscriptApi
except ImportError:
    YouTubeTranscriptApi = None


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print("usage: web_youtube_transcript.py <video_id>", file=sys.stderr)
        return 2
    video_id = args[0]

    if YouTubeTranscriptApi is None:
        print("TRANSCRIPT FAILED: the youtube-transcript-api package is not "
              "installed.", file=sys.stderr)
        print("Install it with: pip install youtube-transcript-api",
              file=sys.stderr)
        return 1

    try:
        youtube_transcript_api = YouTubeTranscriptApi()
        transcript = youtube_transcript_api.fetch(video_id)
        for segment in transcript.snippets:
            mins = int(segment.start) // 60
            secs = int(segment.start) % 60
            print(f"[{mins:02d}:{secs:02d}] {segment.text}")
        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_SEARCH_LOCAL_WEB_SEARCH_SCRIPTS_WEB_YOUTUBE_TRANSCRIPT_PY

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
    # ---- YouTube transcripts: a free tool, but not part of the Firecrawl
    # MCP surface (talks to YouTube directly, no local stack involved) ----
    ("local-web-search/scripts/web_youtube_transcript.py", "local-web-search/scripts/web_youtube_transcript.py"),
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
    ap('REM  with one the credentials are written to .env and all 25 tools install.')
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
    ap('call :genkey BLESSTOKEN')
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
    ap('>> "!TARGET!\\.env" echo # ---- Browserless (stealth headless Chromium) ----')
    ap('>> "!TARGET!\\.env" echo BROWSERLESS_TOKEN=!BLESSTOKEN!')
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
    ap('#  with one the credentials are written to .env and all 25 tools install.')
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
    ap('SECRET="$(genkey)"; BULL="$(genkey)"; PGPASS="$(genkey)"; RABPASS="$(genkey)"; BLESSTOKEN="$(genkey)"')
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
    ap('  echo "# ---- Browserless (stealth headless Chromium) ----"')
    ap('  echo "BROWSERLESS_TOKEN=$BLESSTOKEN"')
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
  * the full local-search source tree (45 files; the generated installers
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
    # ---- YouTube transcripts: a free tool, but not part of the Firecrawl
    # MCP surface (talks to YouTube directly, no local stack involved) ----
    "local-web-search/scripts/web_youtube_transcript.py",
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
    "local-web-search/scripts/web_youtube_transcript.py",
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
    "local-web-search/scripts/web_youtube_transcript.py",
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
#     and verifies all 25 tools install, the credentials land in .env, and
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
check "local-web-search/scripts/web_youtube_transcript.py"
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
if grep -q "6 tools: search, scrape, map, crawl, crawl status, YouTube" "$TGT_DIR/local-web-search/SKILL.md" \
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
         scripts/web_search.py scripts/web_scrape.py scripts/web_youtube_transcript.py \
         scripts/web_map.py scripts/web_crawl.py scripts/web_crawl_status.py"

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

# --- account-mode install: a Firecrawl account installs all 25 tools ------
echo
echo "===== account-mode install: fake Firecrawl account -> all 25 tools ====="

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
   && ! grep -q "6 tools: search, scrape, map, crawl, crawl status, YouTube" "$SKILL_DIR/SKILL.md" \
   && [ ! -e "$SKILL_DIR/SKILL-core.md" ] \
   && [ ! -e "$TGT3/local-web-search/SKILL-core.md" ]; then
  echo "  [OK]   SKILL.md is the full 25-tool variant (SKILL-core.md cleaned up)"
else
  echo "  [FAIL] SKILL.md variant wrong in account mode"; PASS=0
fi

ALL_SKILL_FILES="SKILL.md scripts/config.py scripts/ensure_stack.py scripts/firecrawl_api.py \
         scripts/web_search.py scripts/web_scrape.py scripts/web_youtube_transcript.py \
         scripts/web_map.py \
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
  echo "  [OK]   all 25 tool scripts + shared modules in the account-mode skill"
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
         local-web-search/scripts/web_youtube_transcript.py \
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
if grep -q "6 tools: search, scrape, map, crawl, crawl status, YouTube" "$TGT/local-web-search/SKILL.md"; then
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
         local-web-search/scripts/web_search.py local-web-search/scripts/web_scrape.py \
         local-web-search/scripts/web_youtube_transcript.py; do
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
REM    * the local-search source tree (45 files)
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
echo   Will unpack 57 files into: !TARGET!
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
>> "!B64TMP!" echo ZS9jcmF3bC9zZWFyY2gvbWFwIEFQSSAgLT4gaG9zdCAke0ZJUkVDUkFXTF9QT1JUfQojICAgIGJy
>> "!B64TMP!" echo b3dzZXJsZXNzICAgICAgIHN0ZWFsdGggSlMgcmVuZGVyaW5nIGZvciBGaXJlY3Jhd2wgKEJyb3dz
>> "!B64TMP!" echo ZXJsZXNzIENFKQojICAgIHJlZGlzICAgICAgICAgICAgICAgcXVldWUgZm9yIEZpcmVjcmF3bAoj
>> "!B64TMP!" echo ICAgIHJhYmJpdG1xICAgICAgICAgICAgbWVzc2FnZSBicm9rZXIgZm9yIEZpcmVjcmF3bAojICAg
>> "!B64TMP!" echo IG51cS1wb3N0Z3JlcyAgICAgICAgam9iIHN0YXRlIERCIGZvciBGaXJlY3Jhd2wKIwojICBPbmx5
>> "!B64TMP!" echo IHRoZSB0d28gaG9zdCBwb3J0cyBiZWxvdyBhcmUgcHVibGlzaGVkLiBFdmVyeXRoaW5nIGVsc2Ug
>> "!B64TMP!" echo c3RheXMgb24gdGhlCiMgIHByaXZhdGUgImxvY2FsLXNlYXJjaC1uZXQiIGJyaWRnZSBuZXR3b3Jr
>> "!B64TMP!" echo LgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09CgpuYW1lOiBsb2NhbC1zZWFyY2gKCnNlcnZpY2VzOgoK
>> "!B64TMP!" echo ICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgIyBTZWFyWE5HIOKAlCBwcml2YWN5LXJlc3BlY3Rpbmcg
>> "!B64TMP!" echo bWV0YXNlYXJjaCBlbmdpbmUsIGV4cG9zZWQgYXMgYSBKU09OIEFQSS4KICAjIFBvd2VycyBib3Ro
>> "!B64TMP!" echo IHlvdXIgQUkgbW9kZWxzIChkaXJlY3QgSlNPTiBxdWVyaWVzKSBhbmQgRmlyZWNyYXdsJ3MgL3Yx
>> "!B64TMP!" echo L3NlYXJjaC4KICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgc2VhcnhuZzoKICAgIGltYWdlOiBzZWFy
>> "!B64TMP!" echo eG5nL3NlYXJ4bmc6bGF0ZXN0CiAgICBjb250YWluZXJfbmFtZTogbG9jYWwtc2VhcmNoLXNlYXJ4
>> "!B64TMP!" echo bmcKICAgIHBvcnRzOgogICAgICAtICIke1NFQVJYTkdfUE9SVDotOTk5MH06ODA4MCIKICAgIHZv
>> "!B64TMP!" echo bHVtZXM6CiAgICAgIC0gLi9jb25maWcvc2VhcnhuZzovZXRjL3NlYXJ4bmc6cncKICAgIGVudmly
>> "!B64TMP!" echo b25tZW50OgogICAgICAtIFNFQVJYTkdfQkFTRV9VUkw9aHR0cDovL2xvY2FsaG9zdDoke1NFQVJY
>> "!B64TMP!" echo TkdfUE9SVDotOTk5MH0vCiAgICAgIC0gVVdTR0lfV09SS0VSUz00CiAgICAgIC0gVVdTR0lfVEhS
>> "!B64TMP!" echo RUFEUz00CiAgICAgIC0gU0VBUlhOR19TRUNSRVQ9JHtTRUFSWE5HX1NFQ1JFVH0KICAgIHJlc3Rh
>> "!B64TMP!" echo cnQ6IHVubGVzcy1zdG9wcGVkCiAgICBjYXBfZHJvcDoKICAgICAgLSBBTEwKICAgIGNhcF9hZGQ6
>> "!B64TMP!" echo CiAgICAgIC0gQ0hPV04KICAgICAgLSBTRVRHSUQKICAgICAgLSBTRVRVSUQKICAgIG5ldHdvcmtz
>> "!B64TMP!" echo OgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMgRmly
>> "!B64TMP!" echo ZWNyYXdsIEFQSSBzZXJ2ZXIgKHRoZSBwdWJsaWMtZmFjaW5nIHNjcmFwaW5nL2NyYXdsL3NlYXJj
>> "!B64TMP!" echo aCBzZXJ2aWNlKS4KICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgZmlyZWNyYXdsOgogICAgaW1hZ2U6
>> "!B64TMP!" echo IGdoY3IuaW8vZmlyZWNyYXdsL2ZpcmVjcmF3bDpsYXRlc3QKICAgIGNvbnRhaW5lcl9uYW1lOiBs
>> "!B64TMP!" echo b2NhbC1zZWFyY2gtZmlyZWNyYXdsCiAgICBwb3J0czoKICAgICAgLSAiJHtGSVJFQ1JBV0xfUE9S
>> "!B64TMP!" echo VDotOTk5MX06MzAwMiIKICAgIGVudmlyb25tZW50OgogICAgICAtIFBPUlQ9MzAwMgogICAgICAt
>> "!B64TMP!" echo IEhPU1Q9MC4wLjAuMAogICAgICAtIEVOVj1sb2NhbAogICAgICAtIFJFRElTX1VSTD1yZWRpczov
>> "!B64TMP!" echo L3JlZGlzOjYzNzkKICAgICAgLSBSRURJU19SQVRFX0xJTUlUX1VSTD1yZWRpczovL3JlZGlzOjYz
>> "!B64TMP!" echo NzkKICAgICAgLSBQTEFZV1JJR0hUX01JQ1JPU0VSVklDRV9VUkw9aHR0cDovL2Jyb3dzZXJsZXNz
>> "!B64TMP!" echo OjMwMDAvc2NyYXBlCiAgICAgIC0gVVNFX0RCX0FVVEhFTlRJQ0FUSU9OPWZhbHNlCiAgICAgIC0g
>> "!B64TMP!" echo QlVMTF9BVVRIX0tFWT0ke0JVTExfQVVUSF9LRVl9CiAgICAgIC0gTE9HR0lOR19MRVZFTD0ke0xP
>> "!B64TMP!" echo R0dJTkdfTEVWRUw6LWluZm99CiAgICAgIC0gQkxPQ0tfTUVESUE9ZmFsc2UKICAgICAgLSBBTExP
>> "!B64TMP!" echo V19MT0NBTF9XRUJIT09LUz1mYWxzZQogICAgICAtIFNFQVJYTkdfRU5EUE9JTlQ9aHR0cDovL3Nl
>> "!B64TMP!" echo YXJ4bmc6ODA4MAogICAgICAtIFBPU1RHUkVTX0hPU1Q9bnVxLXBvc3RncmVzCiAgICAgIC0gUE9T
>> "!B64TMP!" echo VEdSRVNfUE9SVD01NDMyCiAgICAgIC0gUE9TVEdSRVNfREI9JHtQT1NUR1JFU19EQjotZmlyZWNy
>> "!B64TMP!" echo YXdsfQogICAgICAtIFBPU1RHUkVTX1VTRVI9JHtQT1NUR1JFU19VU0VSOi1maXJlY3Jhd2x9CiAg
>> "!B64TMP!" echo ICAgIC0gUE9TVEdSRVNfUEFTU1dPUkQ9JHtQT1NUR1JFU19QQVNTV09SRH0KICAgICAgLSBOVVFf
>> "!B64TMP!" echo UkFCQklUTVFfVVJMPWFtcXA6Ly8ke1JBQkJJVE1RX1VTRVI6LWZpcmVjcmF3bH06JHtSQUJCSVRN
>> "!B64TMP!" echo UV9QQVNTV09SRH1AcmFiYml0bXE6NTY3MgogICAgICAjIC0tLS0gT3B0aW9uYWwgQUkgZmVhdHVy
>> "!B64TMP!" echo ZXMgKHNldCBpbiAuZW52IHRvIGVuYWJsZSAvdjEvZXh0cmFjdCArIHN1bW1hcnkpIC0tLS0KICAg
>> "!B64TMP!" echo ICAgLSBPUEVOQUlfQVBJX0tFWT0ke09QRU5BSV9BUElfS0VZOi19CiAgICAgIC0gT1BFTkFJX0JB
>> "!B64TMP!" echo U0VfVVJMPSR7T1BFTkFJX0JBU0VfVVJMOi19CiAgICAgIC0gT0xMQU1BX0JBU0VfVVJMPSR7T0xM
>> "!B64TMP!" echo QU1BX0JBU0VfVVJMOi19CiAgICAgIC0gTU9ERUxfTkFNRT0ke01PREVMX05BTUU6LX0KICAgICAg
>> "!B64TMP!" echo LSBNT0RFTF9FTUJFRERJTkdfTkFNRT0ke01PREVMX0VNQkVERElOR19OQU1FOi19CiAgICBjb21t
>> "!B64TMP!" echo YW5kOiBbIm5vZGUiLCAiZGlzdC9zcmMvaGFybmVzcy5qcyIsICItLXN0YXJ0LWRvY2tlciJdCiAg
>> "!B64TMP!" echo ICB1bGltaXRzOgogICAgICBub2ZpbGU6CiAgICAgICAgc29mdDogNjU1MzUKICAgICAgICBoYXJk
>> "!B64TMP!" echo OiA2NTUzNQogICAgZXh0cmFfaG9zdHM6CiAgICAgIC0gImhvc3QuZG9ja2VyLmludGVybmFsOmhv
>> "!B64TMP!" echo c3QtZ2F0ZXdheSIKICAgIGxvZ2dpbmc6CiAgICAgIGRyaXZlcjogImpzb24tZmlsZSIKICAgICAg
>> "!B64TMP!" echo b3B0aW9uczoKICAgICAgICBtYXgtc2l6ZTogIjEwbSIKICAgICAgICBtYXgtZmlsZTogIjMiCiAg
>> "!B64TMP!" echo ICAgICAgY29tcHJlc3M6ICJ0cnVlIgogICAgZGVwZW5kc19vbjoKICAgICAgcmVkaXM6CiAgICAg
>> "!B64TMP!" echo ICAgY29uZGl0aW9uOiBzZXJ2aWNlX3N0YXJ0ZWQKICAgICAgYnJvd3Nlcmxlc3M6CiAgICAgICAg
>> "!B64TMP!" echo Y29uZGl0aW9uOiBzZXJ2aWNlX3N0YXJ0ZWQKICAgICAgc2VhcnhuZzoKICAgICAgICBjb25kaXRp
>> "!B64TMP!" echo b246IHNlcnZpY2Vfc3RhcnRlZAogICAgICBudXEtcG9zdGdyZXM6CiAgICAgICAgY29uZGl0aW9u
>> "!B64TMP!" echo OiBzZXJ2aWNlX2hlYWx0aHkKICAgICAgcmFiYml0bXE6CiAgICAgICAgY29uZGl0aW9uOiBzZXJ2
>> "!B64TMP!" echo aWNlX2hlYWx0aHkKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBuZXR3b3JrczoKICAg
>> "!B64TMP!" echo ICAgLSBsb2NhbC1zZWFyY2gtbmV0CgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAjIEJyb3dzZXJs
>> "!B64TMP!" echo ZXNzIChjb21tdW5pdHkgZWRpdGlvbikg4oCUIHN0ZWFsdGggaGVhZGxlc3MgQ2hyb21pdW0gdGhh
>> "!B64TMP!" echo dCBkb2VzIHRoZQogICMgYWN0dWFsIEpTLXJlbmRlcmVkIGZldGNoaW5nIGZvciBGaXJlY3Jhd2wu
>> "!B64TMP!" echo IERFRkFVTFRfU1RFQUxUSD10cnVlIGFwcGxpZXMKICAjIHRoZSBidWlsdC1pbiBzdGVhbHRoIHBh
>> "!B64TMP!" echo dGNoZXMgKG1hc2tzIGF1dG9tYXRpb24gZmluZ2VycHJpbnRzIHN1Y2ggYXMKICAjIG5hdmlnYXRv
>> "!B64TMP!" echo ci53ZWJkcml2ZXIpIHRvIGV2ZXJ5IHJlcXVlc3Qgd2l0aG91dCBuZWVkaW5nIGEgP3N0ZWFsdGgg
>> "!B64TMP!" echo cXVlcnkKICAjIHBhcmFtLCB3aGljaCBoZWxwcyBwYWdlcyBmcm9udGVkIGJ5IENsb3VkZmxhcmUg
>> "!B64TMP!" echo YW5kIHNpbWlsYXIgYm90IGNoZWNrcy4KICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgYnJvd3Nlcmxl
>> "!B64TMP!" echo c3M6CiAgICBpbWFnZTogZ2hjci5pby9icm93c2VybGVzcy9jaHJvbWl1bTpsYXRlc3QKICAgIGNv
>> "!B64TMP!" echo bnRhaW5lcl9uYW1lOiBsb2NhbC1zZWFyY2gtYnJvd3Nlcmxlc3MKICAgIGVudmlyb25tZW50Ogog
>> "!B64TMP!" echo ICAgICAtIFBPUlQ9MzAwMAogICAgICAtIFRPS0VOPSR7QlJPV1NFUkxFU1NfVE9LRU46LX0KICAg
>> "!B64TMP!" echo ICAgLSBERUZBVUxUX1NURUFMVEg9dHJ1ZQogICAgICAtIENPTkNVUlJFTlQ9MTAKICAgICAgLSBN
>> "!B64TMP!" echo QVhfQ09OQ1VSUkVOVF9TRVNTSU9OUz0xMAogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAg
>> "!B64TMP!" echo IG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCiAgIyAtLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LQogICMgUmVkaXMg4oCUIEZpcmVjcmF3bCBxdWV1ZSAvIHJhdGUtbGltaXRpbmcgc3RvcmUuCiAg
>> "!B64TMP!" echo IyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLQogIHJlZGlzOgogICAgaW1hZ2U6IHJlZGlzOmFscGluZQogICAg
>> "!B64TMP!" echo Y29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1yZWRpcwogICAgdm9sdW1lczoKICAgICAgLSBy
>> "!B64TMP!" echo ZWRpcy1kYXRhOi9kYXRhCiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgbmV0d29ya3M6
>> "!B64TMP!" echo CiAgICAgIC0gbG9jYWwtc2VhcmNoLW5ldAoKICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgIyBSYWJi
>> "!B64TMP!" echo aXRNUSDigJQgbWVzc2FnZSBicm9rZXIgdXNlZCBieSBGaXJlY3Jhd2wncyBqb2Igd29ya2Vycy4K
>> "!B64TMP!" echo ICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgcmFiYml0bXE6CiAgICBpbWFnZTogcmFiYml0bXE6My1t
>> "!B64TMP!" echo YW5hZ2VtZW50CiAgICBjb250YWluZXJfbmFtZTogbG9jYWwtc2VhcmNoLXJhYmJpdG1xCiAgICBl
>> "!B64TMP!" echo bnZpcm9ubWVudDoKICAgICAgLSBSQUJCSVRNUV9ERUZBVUxUX1VTRVI9JHtSQUJCSVRNUV9VU0VS
>> "!B64TMP!" echo Oi1maXJlY3Jhd2x9CiAgICAgIC0gUkFCQklUTVFfREVGQVVMVF9QQVNTPSR7UkFCQklUTVFfUEFT
>> "!B64TMP!" echo U1dPUkR9CiAgICB2b2x1bWVzOgogICAgICAtIHJhYmJpdG1xLWRhdGE6L3Zhci9saWIvcmFiYml0
>> "!B64TMP!" echo bXEKICAgIGhlYWx0aGNoZWNrOgogICAgICB0ZXN0OiBbIkNNRCIsICJyYWJiaXRtcS1kaWFnbm9z
>> "!B64TMP!" echo dGljcyIsICJwaW5nIl0KICAgICAgaW50ZXJ2YWw6IDVzCiAgICAgIHRpbWVvdXQ6IDEwcwogICAg
>> "!B64TMP!" echo ICByZXRyaWVzOiAxMAogICAgICBzdGFydF9wZXJpb2Q6IDMwcwogICAgcmVzdGFydDogdW5sZXNz
>> "!B64TMP!" echo LXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCiAgIyAtLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLQogICMgbnVxLXBvc3RncmVzIOKAlCBGaXJlY3Jhd2wgam9iLXN0YXRlIGRh
>> "!B64TMP!" echo dGFiYXNlIChwZ19jcm9uIGVuYWJsZWQgaW1hZ2UpLgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICBu
>> "!B64TMP!" echo dXEtcG9zdGdyZXM6CiAgICBpbWFnZTogZ2hjci5pby9maXJlY3Jhd2wvbnVxLXBvc3RncmVzOmxh
>> "!B64TMP!" echo dGVzdAogICAgY29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1wb3N0Z3JlcwogICAgY29tbWFu
>> "!B64TMP!" echo ZDogcG9zdGdyZXMgLWMgY3Jvbi5kYXRhYmFzZV9uYW1lPSR7UE9TVEdSRVNfREI6LWZpcmVjcmF3
>> "!B64TMP!" echo bH0KICAgIGVudmlyb25tZW50OgogICAgICAtIFBPU1RHUkVTX0RCPSR7UE9TVEdSRVNfREI6LWZp
>> "!B64TMP!" echo cmVjcmF3bH0KICAgICAgLSBQT1NUR1JFU19VU0VSPSR7UE9TVEdSRVNfVVNFUjotZmlyZWNyYXds
>> "!B64TMP!" echo fQogICAgICAtIFBPU1RHUkVTX1BBU1NXT1JEPSR7UE9TVEdSRVNfUEFTU1dPUkR9CiAgICB2b2x1
>> "!B64TMP!" echo bWVzOgogICAgICAtIHBvc3RncmVzLWRhdGE6L3Zhci9saWIvcG9zdGdyZXNxbC9kYXRhCiAgICBo
>> "!B64TMP!" echo ZWFsdGhjaGVjazoKICAgICAgdGVzdDogWyJDTUQtU0hFTEwiLCAicGdfaXNyZWFkeSAtVSAke1BP
>> "!B64TMP!" echo U1RHUkVTX1VTRVI6LWZpcmVjcmF3bH0gLWQgJHtQT1NUR1JFU19EQjotZmlyZWNyYXdsfSJdCiAg
>> "!B64TMP!" echo ICAgIGludGVydmFsOiA1cwogICAgICB0aW1lb3V0OiA1cwogICAgICByZXRyaWVzOiAxMAogICAg
>> "!B64TMP!" echo ICBzdGFydF9wZXJpb2Q6IDMwcwogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIG5ldHdv
>> "!B64TMP!" echo cmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCm5ldHdvcmtzOgogIGxvY2FsLXNlYXJjaC1u
>> "!B64TMP!" echo ZXQ6CiAgICBkcml2ZXI6IGJyaWRnZQoKdm9sdW1lczoKICByZWRpcy1kYXRhOgogIHBvc3RncmVz
>> "!B64TMP!" echo LWRhdGE6CiAgcmFiYml0bXEtZGF0YToK
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
>> "!B64TMP!" echo QVNTV09SRD1yZXBsYWNlLXdpdGgtNjQtY2hhci1yYW5kb20taGV4CgojIC0tLS0gQnJvd3Nlcmxl
>> "!B64TMP!" echo c3MgKHN0ZWFsdGggaGVhZGxlc3MgQ2hyb21pdW0sIGluc3RhbGxlciBnZW5lcmF0ZXMgYSByYW5k
>> "!B64TMP!" echo b20gdG9rZW4pIC0tLS0KQlJPV1NFUkxFU1NfVE9LRU49cmVwbGFjZS13aXRoLTY0LWNoYXItcmFu
>> "!B64TMP!" echo ZG9tLWhleAoKIyAtLS0tIExvZ2dpbmcgLS0tLQpMT0dHSU5HX0xFVkVMPWluZm8KCiMgPT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT0KIyAgT3B0aW9uYWw6IGNvbm5lY3QgYSBsb2NhbCAob3IgcmVtb3RlKSBM
>> "!B64TMP!" echo TE0gc28gRmlyZWNyYXdsJ3MgL3YxL2V4dHJhY3QgYW5kCiMgICJzdW1tYXJ5IiBmZWF0dXJlcyB3
>> "!B64TMP!" echo b3JrLiBBbnkgT3BlbkFJLWNvbXBhdGlibGUgZW5kcG9pbnQgd2lsbCBkby4KIyAgTE0gU3R1ZGlv
>> "!B64TMP!" echo IGlzIHRoZSByZWNvbW1lbmRlZCBkZWZhdWx0IChwcmlvcml0eSBvdmVyIE9sbGFtYSkuCiMgPT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT0KCiMgLS0tLSBPcHRpb24gQSAoUkVDT01NRU5ERUQpOiBMTSBTdHVk
>> "!B64TMP!" echo aW8gLyBhbnkgT3BlbkFJLWNvbXBhdGlibGUgbG9jYWwgc2VydmVyIC0tLS0KIyAgIDEuIEluIExN
>> "!B64TMP!" echo IFN0dWRpbzogRGV2ZWxvcGVyIHRhYiA+ICJTdGFydCBTZXJ2ZXIiIG9uIHBvcnQgMTIzNCwgbG9h
>> "!B64TMP!" echo ZCBhIG1vZGVsLAojICAgICAgYW5kIEVOQUJMRSAiU2VydmUgb24gbG9jYWwgbmV0d29yayIgc28g
>> "!B64TMP!" echo dGhlIEZpcmVjcmF3bCBjb250YWluZXIgY2FuIHJlYWNoIGl0LgojICAgMi4gTk9URTogT1BFTkFJ
>> "!B64TMP!" echo X0JBU0VfVVJMIGlzIHJlYWQgSU5TSURFIHRoZSBGaXJlY3Jhd2wgY29udGFpbmVyLiBGcm9tIHRo
>> "!B64TMP!" echo ZXJlLAojICAgICAgeW91ciBob3N0IG1hY2hpbmUgaXMgImhvc3QuZG9ja2VyLmludGVybmFsIiwg
>> "!B64TMP!" echo Tk9UICJsb2NhbGhvc3QiLiBTbyB1c2U6CiMgT1BFTkFJX0JBU0VfVVJMPWh0dHA6Ly9ob3N0LmRv
>> "!B64TMP!" echo Y2tlci5pbnRlcm5hbDoxMjM0L3YxCiMgT1BFTkFJX0FQSV9LRVk9bG0tc3R1ZGlvICAgICAgICAg
>> "!B64TMP!" echo ICMgYW55IG5vbi1lbXB0eSBzdHJpbmc7IExNIFN0dWRpbyBpZ25vcmVzIGl0CiMgTU9ERUxfTkFN
>> "!B64TMP!" echo RT1sb2NhbC1tb2RlbCAgICAgICAgICAgICMgdGhlIG1vZGVsIGlkIGxvYWRlZCBpbiBMTSBTdHVk
>> "!B64TMP!" echo aW8KCiMgLS0tLSBPcHRpb24gQjogcmVtb3RlIE9wZW5BSS1jb21wYXRpYmxlIHNlcnZlciAodkxM
>> "!B64TMP!" echo TSwgbGxhbWEuY3BwIHNlcnZlciwgZXRjLikgLS0tLQojIE9QRU5BSV9CQVNFX1VSTD1odHRwOi8v
>> "!B64TMP!" echo MTkyLjE2OC4xLjUwOjgwMDAvdjEKIyBPUEVOQUlfQVBJX0tFWT1wbGFjZWhvbGRlcgojIE1PREVM
>> "!B64TMP!" echo X05BTUU9eW91ci1tb2RlbC1pZAoKIyAtLS0tIE9wdGlvbiBDIChmYWxsYmFjayk6IE9sbGFtYSBv
>> "!B64TMP!" echo biB0aGUgc2FtZSBob3N0IGFzIERvY2tlciAtLS0tCiMgT0xMQU1BX0JBU0VfVVJMPWh0dHA6Ly9o
>> "!B64TMP!" echo b3N0LmRvY2tlci5pbnRlcm5hbDoxMTQzNC9hcGkKIyBNT0RFTF9OQU1FPXF3ZW4yLjU6N2IKIyBN
>> "!B64TMP!" echo T0RFTF9FTUJFRERJTkdfTkFNRT1ub21pYy1lbWJlZC10ZXh0CgojID09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09CiMgIE9wdGlvbmFsOiBGaXJlY3Jhd2wgYWNjb3VudCAocGFpZCBjbG91ZCBzZXJ2aWNlKSBm
>> "!B64TMP!" echo b3IgdGhlIGFjY291bnQtb25seQojICBsb2NhbC13ZWItc2VhcmNoIHRvb2xzIChyZXNlYXJjaCBh
>> "!B64TMP!" echo Z2VudCwgaW50ZXJhY3QsIHBhcnNlLCBtb25pdG9ycywgcGFwZXIKIyAgcmVzZWFyY2gsIEdpdEh1
>> "!B64TMP!" echo Yi9kZXZlbG9wZXIgc2VhcmNoKS4KIwojICBUaGUgaW5zdGFsbGVyIG9mZmVycyB0byB3cml0ZSB0
>> "!B64TMP!" echo aGVzZSBmb3IgeW91IChhbnN3ZXIgJ3knIGF0IHRoZQojICAiQWRkIGEgRmlyZWNyYXdsIGFjY291
>> "!B64TMP!" echo bnQ/IiBxdWVzdGlvbiwgdGhlbiBwYXN0ZSB5b3VyIGtleSkuIFdpdGhvdXQgdGhlbQojICB0aGUg
>> "!B64TMP!" echo aW5zdGFsbGVyIHNraXBzIHRob3NlIHRvb2xzIGFuZCBpbnN0YWxscyBvbmx5IHRoZSBmcmVlIGxv
>> "!B64TMP!" echo Y2FsIG9uZXMuCiMgIFRoZSBsb2NhbC13ZWItc2VhcmNoIHNjcmlwdHMgcmVhZCB0aGVzZSBrZXlz
>> "!B64TMP!" echo IGZyb20gVEhJUyBmaWxlOwojICBGSVJFQ1JBV0xfQVBJX1VSTCAvIEZJUkVDUkFXTF9BUElfS0VZ
>> "!B64TMP!" echo IGVudmlyb25tZW50IHZhcmlhYmxlcyBvdmVycmlkZSB0aGVtLgojICAoVGhlIERvY2tlciBjb250
>> "!B64TMP!" echo YWluZXJzIGlnbm9yZSB0aGVzZSBrZXlzIGVudGlyZWx5LikKIyA9PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PQojIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYKIyBGSVJFQ1JB
>> "!B64TMP!" echo V0xfQVBJX0tFWT1mYy15b3VyLWtleS1oZXJlCg==
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
>> "!B64TMP!" echo KipubyBBUEkga2V5IG5lZWRlZCoqIGZvciBsb2NhbCB1c2UuIHwKfCAqKmJyb3dzZXJsZXNzKiog
>> "!B64TMP!" echo fCBgZ2hjci5pby9icm93c2VybGVzcy9jaHJvbWl1bTpsYXRlc3RgIHwgU3RlYWx0aCBoZWFkbGVz
>> "!B64TMP!" echo cyBDaHJvbWl1bSAoQnJvd3Nlcmxlc3MgQ0UsIGBERUZBVUxUX1NURUFMVEg9dHJ1ZWApIGZvciBK
>> "!B64TMP!" echo YXZhU2NyaXB0LXJlbmRlcmVkIHBhZ2VzLiB8CnwgKipyZWRpcyoqIHwgYHJlZGlzOmFscGluZWAg
>> "!B64TMP!" echo fCBGaXJlY3Jhd2wgam9iIHF1ZXVlLiB8CnwgKipyYWJiaXRtcSoqIHwgYHJhYmJpdG1xOjMtbWFu
>> "!B64TMP!" echo YWdlbWVudGAgfCBGaXJlY3Jhd2wgbWVzc2FnZSBicm9rZXIuIHwKfCAqKm51cS1wb3N0Z3Jlcyoq
>> "!B64TMP!" echo IHwgYGdoY3IuaW8vZmlyZWNyYXdsL251cS1wb3N0Z3JlczpsYXRlc3RgIHwgRmlyZWNyYXdsIGpv
>> "!B64TMP!" echo Yi1zdGF0ZSBEQiAocGdfY3JvbiBlbmFibGVkKS4gfAoKT24gdG9wIG9mIHRoZSBjb250YWluZXJz
>> "!B64TMP!" echo LCB0aGUgaW5zdGFsbGVyIGJ1bmRsZXMgKipsb2NhbC13ZWItc2VhcmNoKiog4oCUIGEgc2tpbGwg
>> "!B64TMP!" echo Zm9yCmFnZW50cyB0aGF0IGxvYWQgc2tpbGxzIGZyb20gYH4vLmFnZW50cy9za2lsbHMvYCAoYEM6
>> "!B64TMP!" echo XFVzZXJzXFlvdVwuYWdlbnRzXHNraWxsc1xgCm9uIFdpbmRvd3MpLiBJdCBnaXZlcyB0aGUgYWdl
>> "!B64TMP!" echo bnQgYSBjb21wbGV0ZSB3ZWItcmVzZWFyY2ggd29ya2Zsb3c6IHNlYXJjaCB2aWEKU2VhclhORywg
>> "!B64TMP!" echo cmVhZCBwYWdlcyB2aWEgRmlyZWNyYXdsLCBhbmQgZXZlbiBzdGFydCB0aGUgRG9ja2VyIHN0YWNr
>> "!B64TMP!" echo CmF1dG9tYXRpY2FsbHkgd2hlbiBpdCdzIGRvd24uIFNlZSBbc2VjdGlvbiBBXSgjYS10aGUtYnVu
>> "!B64TMP!" echo ZGxlZC1sb2NhbC13ZWItc2VhcmNoLXNraWxsLXJlY29tbWVuZGVkKS4KCk9ubHkgKip0d28gaG9z
>> "!B64TMP!" echo dCBwb3J0cyoqIGFyZSBwdWJsaXNoZWQgKGA5OTkwYCBhbmQgYDk5OTFgIGJ5IGRlZmF1bHQpLiBF
>> "!B64TMP!" echo dmVyeXRoaW5nCmVsc2Ugc3RheXMgb24gdGhlIHByaXZhdGUgYGxvY2FsLXNlYXJjaC1uZXRgIGJy
>> "!B64TMP!" echo aWRnZSBuZXR3b3JrLiBGaXJlY3Jhd2wncwpgL3YxL3NlYXJjaGAgZW5kcG9pbnQgaXMgYXV0b21h
>> "!B64TMP!" echo dGljYWxseSB3aXJlZCB0byBTZWFyWE5HIGludGVybmFsbHksIHNvIGEgc2luZ2xlCkZpcmVjcmF3
>> "!B64TMP!" echo bCBjYWxsIGNhbiBib3RoIHNlYXJjaCAqYW5kKiBmZXRjaCBmdWxsIHBhZ2UgY29udGVudC4KCi0t
>> "!B64TMP!" echo LQoKIyMgUmVxdWlyZW1lbnRzCgotICoqRG9ja2VyKiogd2l0aCB0aGUgKipDb21wb3NlIHYyIHBs
>> "!B64TMP!" echo dWdpbioqIChgZG9ja2VyIGNvbXBvc2VgKS4KICAtIFdpbmRvd3MgLyBtYWNPUzogW0RvY2tlciBE
>> "!B64TMP!" echo ZXNrdG9wXShodHRwczovL3d3dy5kb2NrZXIuY29tL3Byb2R1Y3RzL2RvY2tlci1kZXNrdG9wLykK
>> "!B64TMP!" echo ICAtIExpbnV4OiBbRG9ja2VyIEVuZ2luZV0oaHR0cHM6Ly9kb2NzLmRvY2tlci5jb20vZW5naW5l
>> "!B64TMP!" echo L2luc3RhbGwvKSArIHRoZSBgZG9ja2VyLWNvbXBvc2UtcGx1Z2luYCBwYWNrYWdlLiBBZGQgeW91
>> "!B64TMP!" echo ciB1c2VyIHRvIHRoZSBgZG9ja2VyYCBncm91cCBzbyB5b3UgZG9uJ3QgbmVlZCBgc3Vkb2AuCi0g
>> "!B64TMP!" echo Kip+NSBHQiBmcmVlIGRpc2sqKiBmb3IgaW1hZ2VzIGFuZCBkYXRhLgotICoqOCBHQiBSQU0gLyA0
>> "!B64TMP!" echo IENQVSBjb3JlcyoqIHJlY29tbWVuZGVkICh0aGUgRmlyZWNyYXdsICsgQnJvd3Nlcmxlc3Mgc3Rh
>> "!B64TMP!" echo Y2sgaXMgdGhlIGhlYXZ5IHBhcnQ7IHJlZHVjZSByZXNvdXJjZSBsaW1pdHMgaW4gYGRvY2tlci1j
>> "!B64TMP!" echo b21wb3NlLnltbGAgZm9yIHNtYWxsZXIgaG9zdHMpLgotICoqUHl0aG9uIDMuOCsqKiBmb3IgdGhl
>> "!B64TMP!" echo IGJ1bmRsZWQgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCBzY3JpcHRzIChvcHRpb25hbCBidXQgcmVj
>> "!B64TMP!" echo b21tZW5kZWQg4oCUIGl0J3MgdGhlIGVhc2llc3Qgd2F5IHRvIHVzZSB0aGUgc3RhY2spLgotICoo
>> "!B64TMP!" echo T3B0aW9uYWwsIGZvciBGaXJlY3Jhd2wgQUkgZmVhdHVyZXMpKiAqKkxNIFN0dWRpbyoqIG9yIGFu
>> "!B64TMP!" echo eSBPcGVuQUktY29tcGF0aWJsZSBsb2NhbCBzZXJ2ZXIg4oCUIHNlZSBbc2VjdGlvbiBEXSgjZC1j
>> "!B64TMP!" echo b25uZWN0LWEtbG9jYWwtbGxtLWxtLXN0dWRpby1ldGMpLgotICooT3B0aW9uYWwsIGZvciBNQ1Ap
>> "!B64TMP!" echo KiAqKk5vZGUuanMgMTgrKiogc28gYG5weCBmaXJlY3Jhd2wtbWNwYCB3b3Jrcy4KClZlcmlmeSBE
>> "!B64TMP!" echo b2NrZXIgaXMgcmVhZHk6CgpgYGBiYXNoCmRvY2tlciBpbmZvICAgICAgICAgICAgIyBlbmdpbmUg
>> "!B64TMP!" echo aXMgcnVubmluZwpkb2NrZXIgY29tcG9zZSB2ZXJzaW9uICMgdjIgaXMgaW5zdGFsbGVkCmBgYAoK
>> "!B64TMP!" echo LS0tCgojIyBRdWljayBzdGFydCAob25lLWNsaWNrIGluc3RhbGwpCgo+ICoqVGhlIGluc3RhbGxl
>> "!B64TMP!" echo ciBpcyBzZWxmLWNvbnRhaW5lZC4qKiBFdmVyeSBmaWxlIGl0IG5lZWRzIChgZG9ja2VyLWNvbXBv
>> "!B64TMP!" echo c2UueW1sYCwKPiBgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYCwgYC5lbnYuZXhhbXBsZWAs
>> "!B64TMP!" echo IHRoZSBidW5kbGVkIGBsb2NhbC13ZWItc2VhcmNoYCBza2lsbCwKPiBhbGwgdGhlIHJ1bi9zdG9w
>> "!B64TMP!" echo L3VwZGF0ZS91bmluc3RhbGwgc2NyaXB0cywgdGhpcyBSRUFETUUsIGFuZCBldmVuIHRoZSAqb3Ro
>> "!B64TMP!" echo ZXIqCj4gcGxhdGZvcm0ncyBpbnN0YWxsZXIpIGlzIGVtYmVkZGVkIGluc2lkZSBpdC4gWW91IGNh
>> "!B64TMP!" echo biBkb3dubG9hZCAqKmp1c3QKPiBgaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0YCoqIChXaW5kb3dz
>> "!B64TMP!" echo KSBvciAqKmp1c3QgYGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoYCoqCj4gKExpbnV4L21hY09TKSBv
>> "!B64TMP!" echo biBpdHMgb3duIGFuZCB0aGUgaW5zdGFsbGVyIHdpbGwgc3RpbGwgcHJvZHVjZSBhIGNvbXBsZXRl
>> "!B64TMP!" echo LAo+IHdvcmtpbmcgZm9sZGVyLiBEb3dubG9hZGluZyB0aGUgd2hvbGUgYGxvY2FsLXNlYXJjaGAg
>> "!B64TMP!" echo Zm9sZGVyIG9yIHRoZSB6aXAganVzdAo+IG1ha2VzIHRoZSBpbnN0YWxsIGEgbGl0dGxlIGZhc3Rl
>> "!B64TMP!" echo ciAoaXQgY29waWVzIGZpbGVzIGluc3RlYWQgb2YgZGVjb2RpbmcgdGhlbSkuCgpSdW4gKipvbmUq
>> "!B64TMP!" echo KiBpbnN0YWxsZXIgZm9yIHlvdXIgcGxhdGZvcm0uIEl0IHdpbGwgYXNrIHlvdSBhIGZldyB0aGlu
>> "!B64TMP!" echo Z3Mg4oCUIGluc3RhbGwKZm9sZGVyLCBTZWFyWE5HIHBvcnQsIEZpcmVjcmF3bCBwb3J0LCAob3B0
>> "!B64TMP!" echo aW9uYWxseSkgYSBsb2NhbCBMTE0sIGFuZAoob3B0aW9uYWxseSkgYSBGaXJlY3Jhd2wgYWNjb3Vu
>> "!B64TMP!" echo dCDigJQgd2l0aCBzZW5zaWJsZSBkZWZhdWx0cyB5b3UgY2FuIGFjY2VwdCBieQpwcmVzc2luZyAq
>> "!B64TMP!" echo KkVudGVyKiouIEl0IHRoZW4gZ2VuZXJhdGVzIGNyeXB0b2dyYXBoaWNhbGx5LXNlY3VyZSBjcmVk
>> "!B64TMP!" echo ZW50aWFscywKd3JpdGVzIHlvdXIgYC5lbnZgLCAqKmluc3RhbGxzIHRoZSBsb2NhbC13ZWItc2Vh
>> "!B64TMP!" echo cmNoIHNraWxsKiosIHB1bGxzIHRoZQppbWFnZXMsIGFuZCBzdGFydHMgdGhlIHN0YWNrLgoKPiAq
>> "!B64TMP!" echo KkRvY2tlciBpc24ndCBydW5uaW5nPyoqIE5vIHByb2JsZW0g4oCUIHRoZSBpbnN0YWxsZXIgc3Rh
>> "!B64TMP!" echo cnRzIGl0IGZvciB5b3U6IGl0Cj4gbGF1bmNoZXMgRG9ja2VyIERlc2t0b3AgKFdpbmRvd3MvbWFj
>> "!B64TMP!" echo T1MpIG9yIHRoZSBEb2NrZXIgc2VydmljZQo+IChgc3lzdGVtY3RsYC9gc2VydmljZWAsIExpbnV4
>> "!B64TMP!" echo KSBhbmQgd2FpdHMgdXAgdG8gNSBtaW51dGVzIGZvciB0aGUgZW5naW5lIHdoaWxlCj4geW91IGFu
>> "!B64TMP!" echo c3dlciB0aGUgcHJvbXB0cy4gKE92ZXJyaWRlIHRoZSB3YWl0IHdpdGggdGhlCj4gYExPQ0FMX1NF
>> "!B64TMP!" echo QVJDSF9ET0NLRVJfVElNRU9VVGAgZW52IHZhciwgaW4gc2Vjb25kcy4pCgojIyMgV2luZG93cwoK
>> "!B64TMP!" echo MS4gSW5zdGFsbCBbRG9ja2VyIERlc2t0b3BdKGh0dHBzOi8vd3d3LmRvY2tlci5jb20vcHJvZHVj
>> "!B64TMP!" echo dHMvZG9ja2VyLWRlc2t0b3AvKSDigJQgbm8gbmVlZCB0byBvcGVuIGl0IGZpcnN0OyB0aGUgaW5z
>> "!B64TMP!" echo dGFsbGVyIGxhdW5jaGVzIGl0IGF1dG9tYXRpY2FsbHkuCjIuIERvdWJsZS1jbGljayAqKmBpbnN0
>> "!B64TMP!" echo YWxsLWxvY2FsLXNlYXJjaC5iYXRgKiogKG9yIHJ1biBpdCBmcm9tIGEgdGVybWluYWwpLgoKYGBg
>> "!B64TMP!" echo Ci0tLSBTdGVwIDEgb2YgNTogSW5zdGFsbCBsb2NhdGlvbiAtLS0tLS0tLS0tCiAgVGFyZ2V0IGZv
>> "!B64TMP!" echo bGRlciBbcHJlc3MgRW50ZXIgZm9yIGRlZmF1bHRdOiAgICAgICAgICAgICMgQzpcVXNlcnNcWW91
>> "!B64TMP!" echo XGxvY2FsLXNlYXJjaAotLS0gU3RlcCAyIG9mIDU6IFNlYXJYTkcgcG9ydCAoZGVmYXVsdCA5OTkw
>> "!B64TMP!" echo KSAtLS0tLS0KICBQb3J0IGZvciBTZWFyWE5HIFtwcmVzcyBFbnRlciBmb3IgOTk5MF06IDk5OTAK
>> "!B64TMP!" echo LS0tIFN0ZXAgMyBvZiA1OiBGaXJlY3Jhd2wgcG9ydCAoZGVmYXVsdCA5OTkxKSAtLS0tCiAgUG9y
>> "!B64TMP!" echo dCBmb3IgRmlyZWNyYXdsIFtwcmVzcyBFbnRlciBmb3IgOTk5MV06IDk5OTEKLS0tIFN0ZXAgNCBv
>> "!B64TMP!" echo ZiA1OiBMb2NhbCBMTE0gKG9wdGlvbmFsKSAtLS0tLS0tLS0tLS0tCiAgQ29ubmVjdCBhIGxvY2Fs
>> "!B64TMP!" echo IExMTSBub3c/IFt5L05dOiAgICAgICAgICAgICAgICAgICAgICAgIyBvcHRpb25hbCwgc2VlIHNl
>> "!B64TMP!" echo Y3Rpb24gRAotLS0gU3RlcCA1IG9mIDU6IEZpcmVjcmF3bCBhY2NvdW50IChvcHRpb25hbCkgLS0t
>> "!B64TMP!" echo LS0KICBBZGQgYSBGaXJlY3Jhd2wgYWNjb3VudCBub3c/IFt5L05dOiBuICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAjIGRlZmF1bHQ6IHNraXAsIHNlZSBiZWxvdwpgYGAKCiMjIyBMaW51eCAmIG1hY09TCgpgYGBi
>> "!B64TMP!" echo YXNoCmNobW9kICt4IGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoCi4vaW5zdGFsbC1sb2NhbC1zZWFy
>> "!B64TMP!" echo Y2guc2gKYGBgCgpUaGUgcHJvbXB0cyBhcmUgdGhlIHNhbWUuIERlZmF1bHRzOiBpbnN0YWxsIHRv
>> "!B64TMP!" echo IGB+L2xvY2FsLXNlYXJjaGAsIFNlYXJYTkcgb24KYDk5OTBgLCBGaXJlY3Jhd2wgb24gYDk5OTFg
>> "!B64TMP!" echo LCBubyBGaXJlY3Jhd2wgYWNjb3VudC4gQSBzdG9wcGVkIERvY2tlciBlbmdpbmUKaXMgc3RhcnRl
>> "!B64TMP!" echo ZCBhdXRvbWF0aWNhbGx5IChEb2NrZXIgRGVza3RvcCBvbiBtYWNPUywgYHN5c3RlbWN0bGAvYHNl
>> "!B64TMP!" echo cnZpY2VgIG9uCkxpbnV4KS4KCj4gKipUaGUgb3B0aW9uYWwgRmlyZWNyYXdsIGFjY291bnQgKFN0
>> "!B64TMP!" echo ZXAgNSkuKiogQSBmZXcgb2YgdGhlIGJ1bmRsZWQgc2tpbGwncwo+IHRvb2xzIOKAlCB0aGUgcmVz
>> "!B64TMP!" echo ZWFyY2ggYWdlbnQsIGxpdmUtcGFnZSBgaW50ZXJhY3RgLCBmaWxlIGBwYXJzZWAsIG1vbml0b3Jz
>> "!B64TMP!" echo LAo+IHBhcGVyIHJlc2VhcmNoLCBhbmQgR2l0SHViL2RldmVsb3BlciBzZWFyY2gg4oCUIG9ubHkg
>> "!B64TMP!" echo d29yayBhZ2FpbnN0IEZpcmVjcmF3bCdzCj4gcGFpZCBjbG91ZCBBUEkuIFRoZSBkZWZhdWx0IGFu
>> "!B64TMP!" echo c3dlciBpcyAqKk4qKjogdGhvc2UgdG9vbHMgYXJlIHNpbXBseSAqbm90Cj4gaW5zdGFsbGVkKiwg
>> "!B64TMP!" echo YW5kIHRoZSBza2lsbCBzaGlwcyBhIGxlYW5lciBgU0tJTEwubWRgIGNvdmVyaW5nIGp1c3QgdGhl
>> "!B64TMP!" echo IGZyZWUKPiBsb2NhbCB0b29scy4gQW5zd2VyICoqeSoqIGluc3RlYWQgYW5kIHRoZSBpbnN0YWxs
>> "!B64TMP!" echo ZXIgYXNrcyBmb3IgeW91ciBBUEkga2V5Cj4gKGFuZCBBUEkgVVJMLCBkZWZhdWx0IGBodHRwczov
>> "!B64TMP!" echo L2FwaS5maXJlY3Jhd2wuZGV2YCksIHN0b3JlcyB0aGVtIGluIHlvdXIKPiBgLmVudmAsIGFuZCBp
>> "!B64TMP!" echo bnN0YWxscyB0aGUgZnVsbCAyNS10b29sIHNldC4gWW91IGNhbiBjaGFuZ2UgeW91ciBtaW5kIGxh
>> "!B64TMP!" echo dGVyCj4gYnkgcmUtcnVubmluZyB0aGUgaW5zdGFsbGVyIGFuZCBhbnN3ZXJpbmcgZGlmZmVyZW50
>> "!B64TMP!" echo bHkuCgo+ICoqRmlyc3QgcnVuIGRvd25sb2FkcyB+M+KAkzQgR0Igb2YgRG9ja2VyIGltYWdlcyoq
>> "!B64TMP!" echo ICh0aGUgQnJvd3Nlcmxlc3MgaW1hZ2UgYnVuZGxlcwo+IGEgZnVsbCBDaHJvbWl1bSkuIFN1YnNl
>> "!B64TMP!" echo cXVlbnQgc3RhcnRzIGFyZSBhIGZldyBzZWNvbmRzLgoKV2hlbiBpdCBmaW5pc2hlcyB5b3UnbGwg
>> "!B64TMP!" echo c2VlOgoKYGBgClNlYXJYTkcgIChzZWFyY2ggKyBKU09OIEFQSSk6ICBodHRwOi8vbG9jYWxob3N0
>> "!B64TMP!" echo Ojk5OTAKRmlyZWNyYXdsIChzY3JhcGUvY3Jhd2wgQVBJKTogaHR0cDovL2xvY2FsaG9zdDo5OTkx
>> "!B64TMP!" echo CkFnZW50IHNraWxsOiBDOlxVc2Vyc1xZb3VcLmFnZW50c1xza2lsbHNcbG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aCAgIChvciB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gpCmBgYAoKT3BlbiBgaHR0
>> "!B64TMP!" echo cDovL2xvY2FsaG9zdDo5OTkwYCBpbiBhIGJyb3dzZXIgdG8gc2VlIHRoZSBTZWFyWE5HIHNlYXJj
>> "!B64TMP!" echo aCBVSSDigJQgb3IsCmlmIHlvdXIgYWdlbnQgbG9hZHMgc2tpbGxzIGZyb20gYH4vLmFnZW50cy9z
>> "!B64TMP!" echo a2lsbHMvYCwganVzdCBhc2sgaXQgdG8gcmVzZWFyY2gKc29tZXRoaW5nIGN1cnJlbnQgYW5kIGl0
>> "!B64TMP!" echo IHdpbGwgdXNlICoqbG9jYWwtd2ViLXNlYXJjaCoqIGF1dG9tYXRpY2FsbHkgKHNlZQpbc2VjdGlv
>> "!B64TMP!" echo biBBXSgjYS10aGUtYnVuZGxlZC1sb2NhbC13ZWItc2VhcmNoLXNraWxsLXJlY29tbWVuZGVkKSku
>> "!B64TMP!" echo CgotLS0KCiMjIE1hbmFnaW5nIHRoZSBzdGFjawoKQWZ0ZXIgaW5zdGFsbCwgdGhlIG1hbmFnZW1l
>> "!B64TMP!" echo bnQgc2NyaXB0cyBsaXZlICoqaW4geW91ciBpbnN0YWxsIGZvbGRlcioqCihgQzpcVXNlcnNcWW91
>> "!B64TMP!" echo XGxvY2FsLXNlYXJjaGAgb24gV2luZG93cywgYH4vbG9jYWwtc2VhcmNoYCBvbiBMaW51eC9tYWNP
>> "!B64TMP!" echo UykuClRoZXkgYXV0by1kZXRlY3QgdGhlaXIgb3duIGxvY2F0aW9uLCBzbyB5b3UgY2FuIHJ1biB0
>> "!B64TMP!" echo aGVtIGZyb20gYW55d2hlcmUgYnkKZG91YmxlLWNsaWNraW5nIG9yIGAuL2AtaW5nIHRoZW0uCgp8
>> "!B64TMP!" echo IEFjdGlvbiB8IFdpbmRvd3MgfCBMaW51eCAvIG1hY09TIHwKfC0tLS0tLS0tfC0tLS0tLS0tLXwt
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS18CnwgKipTdGFydCoqIHRoZSBzdGFjayB8IGBSdW4uYmF0YCB8IGAuL3J1
>> "!B64TMP!" echo bi5zaGAgfAp8ICoqU3RvcCoqIChrZWVwIGRhdGEpIHwgYFN0b3AuYmF0YCB8IGAuL3N0b3Auc2hg
>> "!B64TMP!" echo IHwKfCAqKlVwZGF0ZSoqIGltYWdlcyArIGFwcGx5IGAuZW52YCBjaGFuZ2VzICsgKipyZS1zeW5j
>> "!B64TMP!" echo IHRoZSBza2lsbCoqIHwgYFVwZGF0ZS5iYXRgIHwgYC4vdXBkYXRlLnNoYCB8CnwgKipVbmluc3Rh
>> "!B64TMP!" echo bGwqKiAoY29udGFpbmVycyArIHZvbHVtZXMgKyBza2lsbCwgb3B0aW9uYWwgZm9sZGVyIGRlbGV0
>> "!B64TMP!" echo ZSkgfCBgVW5pbnN0YWxsLmJhdGAgfCBgLi91bmluc3RhbGwuc2hgIHwKCi0gKipTdG9wKiogb25s
>> "!B64TMP!" echo eSByZW1vdmVzIGNvbnRhaW5lcnM7IHlvdXIgZGF0YSB2b2x1bWVzIChGaXJlY3Jhd2wgam9iIHN0
>> "!B64TMP!" echo YXRlLAogIHJlZGlzIGNhY2hlLCByYWJiaXRtcS9wb3N0Z3JlcyBkYXRhKSBhcmUgcHJlc2VydmVk
>> "!B64TMP!" echo LgotICoqVXBkYXRlKiogcnVucyBgZG9ja2VyIGNvbXBvc2UgcHVsbGAgdGhlbiBgZG9ja2VyIGNv
>> "!B64TMP!" echo bXBvc2UgdXAgLWRgLCBzbyBpdAogIGJvdGggdXBncmFkZXMgaW1hZ2VzICoqYW5kKiogYXBwbGll
>> "!B64TMP!" echo cyBhbnkgcG9ydC9MTE0gZWRpdHMgeW91IG1hZGUgdG8gYC5lbnZgOwogIGl0IGFsc28gcmUtY29w
>> "!B64TMP!" echo aWVzIHRoZSBidW5kbGVkIGBsb2NhbC13ZWItc2VhcmNoYCBza2lsbCBpbnRvIGB+Ly5hZ2VudHMv
>> "!B64TMP!" echo c2tpbGxzL2AuCi0gKipVbmluc3RhbGwqKiBydW5zIGBkb2NrZXIgY29tcG9zZSBkb3duIC12YCAo
>> "!B64TMP!" echo ZGVsZXRlcyB2b2x1bWVzICsgZGF0YSksCiAgcmVtb3ZlcyB0aGUgYGxvY2FsLXdlYi1zZWFyY2hg
>> "!B64TMP!" echo IHNraWxsIGZyb20gYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaGAsIHRoZW4KICBv
>> "!B64TMP!" echo cHRpb25hbGx5IGRlbGV0ZXMgdGhlIGluc3RhbGwgZm9sZGVyLiBQdWxsZWQgaW1hZ2VzIGFyZSBr
>> "!B64TMP!" echo ZXB0OyByZWNsYWltIHRoZW0KICB3aXRoIGBkb2NrZXIgaW1hZ2UgcHJ1bmUgLWFgIGlmIGRlc2ly
>> "!B64TMP!" echo ZWQuCgotLS0KCiMjIEhvdyBpdCBmaXRzIHRvZ2V0aGVyCgpgYGAKICAgICAgICB5b3VyIEFJIG1v
>> "!B64TMP!" echo ZGVsIC8gYWdlbnQgKGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwpIC8gTUNQIGNsaWVudCAvIGNoYXQg
>> "!B64TMP!" echo VUkKICAgICAgICAgICAgICAgICAgICAgIOKUggogICDilIzilIDilIDilIDilIDilIDilIDilIDi
>> "!B64TMP!" echo lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilLzilIDilIDilIDilIDilIDilIDilIDi
>> "!B64TMP!" echo lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilJAKICAg4pa8ICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg4pa8Cmh0dHA6Ly9sb2NhbGhvc3Q6OTk5
>> "!B64TMP!" echo MCAgICAgICAgICAgIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MQogICDilIIgU2VhclhORyAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICDilIIgRmlyZWNyYXdsIEFQSQogICDilIIgIC0gL3NlYXJjaD9x
>> "!B64TMP!" echo PS4uLiZmb3JtYXQ9anNvbiAgICAgICDilIIgIC0gL3YxL3NjcmFwZSAgIChvbmUgVVJMIC0+IG1h
>> "!B64TMP!" echo cmtkb3duKQogICDilIIgIC0gYWdncmVnYXRlcyB+NzAgZW5naW5lcyAgICAgICAgICAg4pSCICAt
>> "!B64TMP!" echo IC92MS9jcmF3bCAgICAod2hvbGUgc2l0ZSwgYXN5bmMpCiAgIOKUgiAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICDilIIgIC0gL3YxL21hcCAgICAgIChzaXRlIFVSTCB0cmVlKQog
>> "!B64TMP!" echo ICDilIIgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg4pSCICAtIC92MS9zZWFy
>> "!B64TMP!" echo Y2ggICAoLT4gdXNlcyBTZWFyWE5HISkKICAg4pSCICAgICAgICAgICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICAgIOKUgiAgLSAvdjEvZXh0cmFjdCAgKC0+IHVzZXMgeW91ciBMTE0pCiAgIOKUguKX
>> "!B64TMP!" echo hOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCB3aXJlZCB0b2dldGhlciDilIDilIDilIDi
>> "!B64TMP!" echo lIDilIDilIDilIDilIDilIDilIDilKQgIFNFQVJYTkdfRU5EUE9JTlQ9aHR0cDovL3NlYXJ4bmc6
>> "!B64TMP!" echo ODA4MAogICDilIIgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg4pSCCiAgIOKU
>> "!B64TMP!" echo lOKUgOKUgOKUgOKUgOKUgOKUgOKUgCBwcml2YXRlIGRvY2tlciBuZXR3b3JrIOKUgOKUgOKUgOKU
>> "!B64TMP!" echo gOKUgOKUgOKUmAogICAgICAgICAgICAgICAgIGxvY2FsLXNlYXJjaC1uZXQKICAgYWxzbyBvbiBp
>> "!B64TMP!" echo dDogYnJvd3Nlcmxlc3MgKHN0ZWFsdGggQ2hyb21pdW0pLCByZWRpcywgcmFiYml0bXEsIG51cS1w
>> "!B64TMP!" echo b3N0Z3JlcwpgYGAKClRocmVlIGtleSB3aXJpbmcgZGVjaXNpb25zIHRoZSBpbnN0YWxsZXIgbWFr
>> "!B64TMP!" echo ZXMgZm9yIHlvdToKCjEuICoqU2VhclhORyBKU09OICsgbm8gbGltaXRlcioqIOKAlCBgY29uZmln
>> "!B64TMP!" echo L3NlYXJ4bmcvc2V0dGluZ3MueW1sYCBzZXRzCiAgIGBzZWFyY2guZm9ybWF0czogW2h0bWwsIGpz
>> "!B64TMP!" echo b25dYCBhbmQgYHNlcnZlci5saW1pdGVyOiBmYWxzZWAsIHNvIG1vZGVscyBjYW4gaGl0CiAgIGAv
>> "!B64TMP!" echo c2VhcmNoP2Zvcm1hdD1qc29uYCB3aXRob3V0IGJlaW5nIGJsb2NrZWQgYXMgYSBib3QuCjIuICoq
>> "!B64TMP!" echo RmlyZWNyYXdsIOKGkiBTZWFyWE5HKiog4oCUIHRoZSBGaXJlY3Jhd2wgY29udGFpbmVyIHNldHMK
>> "!B64TMP!" echo ICAgYFNFQVJYTkdfRU5EUE9JTlQ9aHR0cDovL3NlYXJ4bmc6ODA4MGAsIHNvIEZpcmVjcmF3bCdz
>> "!B64TMP!" echo IGAvdjEvc2VhcmNoYCB1c2VzIHlvdXIKICAgbG9jYWwgU2VhclhORyBpbnN0ZWFkIG9mIG5lZWRp
>> "!B64TMP!" echo bmcgYSB0aGlyZC1wYXJ0eSBzZWFyY2ggcHJvdmlkZXIuCjMuICoqbG9jYWwtd2ViLXNlYXJjaCBz
>> "!B64TMP!" echo a2lsbCBhdXRvLWluc3RhbGwqKiDigJQgdGhlIGluc3RhbGxlciBjb3BpZXMgdGhlIGJ1bmRsZWQg
>> "!B64TMP!" echo c2tpbGwgdG8KICAgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaC9gIChhZGQvb3Zl
>> "!B64TMP!" echo cnJpZGUpIGFuZCByZWNvcmRzIHRoZSBpbnN0YWxsIHBhdGggaW4KICAgYW4gYGluc3RhbGwtZGly
>> "!B64TMP!" echo LnR4dGAgaGludCBpbnNpZGUgdGhlIHNraWxsLCBzbyB0aGUgc2tpbGwgZmluZHMgdGhlIHN0YWNr
>> "!B64TMP!" echo IGV2ZW4KICAgaWYgeW91IGluc3RhbGxlZCB0byBhIGN1c3RvbSBmb2xkZXIgYW5kIERvY2tlciBp
>> "!B64TMP!" echo c24ndCBydW5uaW5nIHlldC4gV2l0aG91dCBhCiAgIGNvbmZpZ3VyZWQgRmlyZWNyYXdsIGFjY291
>> "!B64TMP!" echo bnQgaXQgaW5zdGFsbHMgb25seSB0aGUgZnJlZSBsb2NhbCB0b29scyBhbmQgYQogICBtYXRjaGlu
>> "!B64TMP!" echo ZyBjb3JlLW9ubHkgYFNLSUxMLm1kYC4KCi0tLQoKIyMgVXNpbmcgaXQgd2l0aCBBSSBtb2RlbHMK
>> "!B64TMP!" echo ClRoZXJlIGFyZSAqKnNldmVuKiogd2F5cyB0byB1c2UgdGhpcyBzeXN0ZW0sIGZyb20gbG93ZXN0
>> "!B64TMP!" echo IHRvIGhpZ2hlc3QKaW50ZWdyYXRpb24uIFBpY2sgd2hhdCBmaXRzIHlvdXIgc3RhY2sg4oCUIHlv
>> "!B64TMP!" echo dSBjYW4gbWl4IGFuZCBtYXRjaC4KCiMjIyBBLiBUaGUgYnVuZGxlZCBsb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo IHNraWxsIChyZWNvbW1lbmRlZCkKClRoZSBpbnN0YWxsZXIgc2hpcHMgd2l0aCAqKmxvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2gqKiwgYW4gYWdlbnQgc2tpbGwgdGhhdCB0dXJucyBhbnkKc2tpbGwtbG9hZGluZyBh
>> "!B64TMP!" echo Z2VudCBpbnRvIGEgd2ViIHJlc2VhcmNoZXIgd2l0aCB6ZXJvIGNvbmZpZ3VyYXRpb24uIElmIHlv
>> "!B64TMP!" echo dXIKYWdlbnQgcmVhZHMgc2tpbGxzIGZyb20gYH4vLmFnZW50cy9za2lsbHMvYAooYEM6XFVzZXJz
>> "!B64TMP!" echo XFlvdVwuYWdlbnRzXHNraWxsc1xgIG9uIFdpbmRvd3MpLCBpdCdzIGFscmVhZHkgYXZhaWxhYmxl
>> "!B64TMP!" echo IGFmdGVyCmluc3RhbGwg4oCUIHJlc3RhcnQgdGhlIGFnZW50IGlmIGl0IHdhcyBydW5uaW5nLgoK
>> "!B64TMP!" echo VGhlIGluc3RhbGxlcjoKLSBwdXRzIGEgY29weSBpbiBgPGluc3RhbGwgZm9sZGVyPi9sb2NhbC13
>> "!B64TMP!" echo ZWItc2VhcmNoL2AsIGFuZAotICoqYXV0b21hdGljYWxseSBpbnN0YWxscyAoYWRkL292ZXJyaWRl
>> "!B64TMP!" echo KSoqIGl0IGludG8KICBgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoL2AuCgpXaGF0
>> "!B64TMP!" echo IHRoZSBza2lsbCBkb2VzIGZvciB0aGUgYWdlbnQ6CgotICoqRmluZHMgdGhlIHN0YWNrIGF1dG9t
>> "!B64TMP!" echo YXRpY2FsbHkuKiogSXQgcmVhZHMgdGhlIHJlYWwgcG9ydHMgZnJvbSB5b3VyIGAuZW52YAogIChz
>> "!B64TMP!" echo byBjdXN0b20gaW5zdGFsbC10aW1lIHBvcnRzIGp1c3Qgd29yaykgYW5kIGxvY2F0ZXMgdGhlIGlu
>> "!B64TMP!" echo c3RhbGwgZm9sZGVyIHZpYQogIHRoZSBjb21wb3NlIGxhYmVscyBvbiB0aGUgcnVubmluZyBjb250
>> "!B64TMP!" echo YWluZXJzLCB0aGUgaW5zdGFsbGVyLXJlY29yZGVkCiAgYGluc3RhbGwtZGlyLnR4dGAgaGludCwg
>> "!B64TMP!" echo b3IgYH4vbG9jYWwtc2VhcmNoYCDigJQgbm8gaGFyZGNvZGVkIGFueXRoaW5nLgotICoqU2VsZi1o
>> "!B64TMP!" echo ZWFscyBhIGRvd24gc3RhY2sg4oCUIG5vIHdhcm0tdXAgc3RlcC4qKiBJZiB0aGUgRG9ja2VyIGVu
>> "!B64TMP!" echo Z2luZSBvciB0aGUKICBjb250YWluZXJzIGFyZSBkb3duIHdoZW4gYSBzZWFyY2gvc2NyYXBlIHJ1
>> "!B64TMP!" echo bnMsIHRoZSBzY3JpcHQgYm9vdHMgdGhlIGVuZ2luZQogIChEb2NrZXIgRGVza3RvcCAvIGBzeXN0
>> "!B64TMP!" echo ZW1jdGwgc3RhcnQgZG9ja2VyYCksIHJ1bnMgdGhlIHNhbWUgYGRvY2tlciBjb21wb3NlCiAgdXAg
>> "!B64TMP!" echo LWRgIHRoYXQgYFJ1bi5iYXRgIC8gYHJ1bi5zaGAgdXNlLCB3YWl0cyBmb3IgdGhlIGVuZHBvaW50
>> "!B64TMP!" echo cywgYW5kIHJldHJpZXMKICB0aGUgcmVxdWVzdCDigJQgc28gdGhlIGFnZW50IGNhbGxzIHRoZSBz
>> "!B64TMP!" echo ZWFyY2gvc2NyYXBlIHNjcmlwdHMgZGlyZWN0bHksIGV2ZW4KICBpbiBhbiBvbGQgY29udmVyc2F0
>> "!B64TMP!" echo aW9uIHdoZXJlIHRoZSBzdGFjayBoYXMgc2luY2UgZ29uZSBkb3duCiAgKGBlbnN1cmVfc3RhY2su
>> "!B64TMP!" echo cHlgIHJlbWFpbnMgYXZhaWxhYmxlIGFzIGFuIG9wdGlvbmFsIHByZS1mbGlnaHQgY2hlY2spLiBU
>> "!B64TMP!" echo aGUKICBzdGFjayBpcyAqKm5ldmVyIHN0b3BwZWQqKiBieSB0aGUgc2NyaXB0cyAoc3RvcHBpbmcg
>> "!B64TMP!" echo aXMgeW91ciBqb2IsIHZpYQogIGBTdG9wLmJhdGAgLyBgc3RvcC5zaGApLgotICoqU2VhcmNoZXMg
>> "!B64TMP!" echo dGhlIHdlYi4qKiBgd2ViX3NlYXJjaC5weSAicXVlcnkiYCBwcmludHMgdGhlIHRvcCByZXN1bHRz
>> "!B64TMP!" echo IGFzCiAgYHRpdGxlIC8gdXJsIC8gc25pcHBldGAsIHdpdGggYC0tbGltaXRgLCBgLS10aW1lLXJh
>> "!B64TMP!" echo bmdlIGRheXx3ZWVrfG1vbnRoYCwgYW5kCiAgYC0tY2F0ZWdvcmllcyBpdCxuZXdzLGdlbmVyYWxg
>> "!B64TMP!" echo IG9wdGlvbnMuCi0gKipSZWFkcyBwYWdlcy4qKiBgd2ViX3NjcmFwZS5weSA8dXJsPmAgcmV0dXJu
>> "!B64TMP!" echo cyB0aGUgcGFnZSBhcyBjbGVhbiBNYXJrZG93bgogICh0cnVuY2F0ZWQgYXQgMjAsMDAwIGNoYXJz
>> "!B64TMP!" echo OyByYWlzZSB3aXRoIGAtLW1heC1jaGFyc2ApLgotICoqUmVhZHMgWW91VHViZSB0cmFuc2NyaXB0
>> "!B64TMP!" echo cy4qKiBgd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weSA8dmlkZW9faWQ+YAogIHByaW50cyBhIHZp
>> "!B64TMP!" echo ZGVvJ3MgY2FwdGlvbnMgYXMgYFtNTTpTU10gdGV4dGAgbGluZXMuIEl0IHRhbGtzIGRpcmVjdGx5
>> "!B64TMP!" echo IHRvCiAgWW91VHViZSDigJQgbm8gRG9ja2VyIHN0YWNrLCBubyBzZWxmLWhlYWwsIG5vIGFjY291
>> "!B64TMP!" echo bnQgbmVlZGVkIOKAlCB2aWEgdGhlCiAgYHlvdXR1YmUtdHJhbnNjcmlwdC1hcGlgIHBpcCBwYWNr
>> "!B64TMP!" echo YWdlIChgcGlwIGluc3RhbGwgeW91dHViZS10cmFuc2NyaXB0LWFwaWA7CiAgdGhlIG9ubHkgdG9v
>> "!B64TMP!" echo bCBoZXJlIHdpdGggYSBwaXAgZGVwZW5kZW5jeSkuCi0gKipFeHBvc2VzIHRoZSBmdWxsIEZpcmVj
>> "!B64TMP!" echo cmF3bCBNQ1Agc3VyZmFjZSDigJQgMjQgdG9vbHMuKiogQmVzaWRlcyBzZWFyY2ggYW5kCiAgc2Ny
>> "!B64TMP!" echo YXBlLCB0aGUgc2tpbGwgc2hpcHMgc2NyaXB0cyBtaXJyb3JpbmcgZXZlcnkgRmlyZWNyYXdsIE1D
>> "!B64TMP!" echo UCB0b29sOgogIGB3ZWJfbWFwLnB5YCAoZW51bWVyYXRlIGEgc2l0ZSdzIFVSTHMpLCBgd2ViX2Ny
>> "!B64TMP!" echo YXdsLnB5YCAvCiAgYHdlYl9jcmF3bF9zdGF0dXMucHlgIChtdWx0aS1wYWdlIGNyYXdscyksIGB3
>> "!B64TMP!" echo ZWJfYWdlbnQucHlgIC8KICBgd2ViX2FnZW50X3N0YXR1cy5weWAgKGFzeW5jIHJlc2VhcmNoIGFn
>> "!B64TMP!" echo ZW50KSwgYHdlYl9pbnRlcmFjdC5weWAgLwogIGB3ZWJfaW50ZXJhY3Rfc3RvcC5weWAgKGxpdmUg
>> "!B64TMP!" echo YnJvd3NlciBzZXNzaW9ucyksIGB3ZWJfcGFyc2UucHlgIChsb2NhbAogIFBERi9Xb3JkL0hUTUwv
>> "!B64TMP!" echo Li4uIGRvY3VtZW50cyksIGVpZ2h0IGB3ZWJfbW9uaXRvcl8qLnB5YCBzY3JpcHRzIChyZWN1cnJp
>> "!B64TMP!" echo bmcKICBjaGFuZ2UgdHJhY2tpbmcpLCBmaXZlIGB3ZWJfcmVzZWFyY2hfKi5weWAgc2NyaXB0cyAo
>> "!B64TMP!" echo YmlvbWVkaWNhbCArIGFyWGl2CiAgcGFwZXIgc2VhcmNoLCBjaXRhdGlvbiBncmFwaCwgZnVsbC10
>> "!B64TMP!" echo ZXh0IHJlYWRpbmcpLCBgd2ViX2dpdGh1Yl9zZWFyY2gucHlgCiAgKGluZGV4ZWQgR2l0SHViIGlz
>> "!B64TMP!" echo c3Vlcy9QUnMvUkVBRE1FcyksIGFuZCBgd2ViX2RldmVsb3Blcl9zZWFyY2gucHlgIChhbgogIGlu
>> "!B64TMP!" echo ZGV4IGJ1aWx0IGZvciBjb2RpbmcgYWdlbnRzKS4gRXZlcnkgc2NyaXB0IHNlbGYtaGVhbHMgdGhl
>> "!B64TMP!" echo IHN0YWNrLCBwcmludHMKICBjbGVhbiBvdXRwdXQsIGFuZCBzdXBwb3J0cyBgLS1qc29uYCBmb3Ig
>> "!B64TMP!" echo dGhlIHJhdyBBUEkgcmVzcG9uc2UuCi0gKipPcHRpb25hbCBhY2NvdW50IGZlYXR1cmVzLioqIFRo
>> "!B64TMP!" echo ZSByZXNlYXJjaCBhZ2VudCwgaW50ZXJhY3QsIHBhcnNlLAogIG1vbml0b3JzLCBwYXBlciByZXNl
>> "!B64TMP!" echo YXJjaCwgYW5kIGRldmVsb3BlciBzZWFyY2ggYXJlIEZpcmVjcmF3bCBhY2NvdW50CiAgZmVhdHVy
>> "!B64TMP!" echo ZXMgKHBhaWQgY2xvdWQgQVBJKS4gVGhlIGluc3RhbGxlcidzICJBZGQgYSBGaXJlY3Jhd2wgYWNj
>> "!B64TMP!" echo b3VudD8iCiAgcXVlc3Rpb24gZGVjaWRlcyBob3cgdGhleSdyZSBoYW5kbGVkOiAqKk4qKiAoZGVm
>> "!B64TMP!" echo YXVsdCkgc2tpcHMgdGhlbSDigJQgdGhlCiAgc2tpbGwgaXMgaW5zdGFsbGVkIHdpdGggb25seSB0
>> "!B64TMP!" echo aGUgZnJlZSBsb2NhbCB0b29scyAoc2VhcmNoLCBzY3JhcGUsIG1hcCwKICBjcmF3bCwgY3Jhd2wg
>> "!B64TMP!" echo c3RhdHVzLCBZb3VUdWJlIHRyYW5zY3JpcHRzKSBhbmQgYSBjb3JlLW9ubHkgYFNLSUxMLm1kYCB0
>> "!B64TMP!" echo aGF0CiAgZG9lc24ndCBtZW50aW9uIHRoZSBhY2NvdW50IHRvb2xzOyAqKnkqKiBpbnN0YWxscyBh
>> "!B64TMP!" echo bGwgMjUgdG9vbHMgYW5kIHdyaXRlcwogIGBGSVJFQ1JBV0xfQVBJX1VSTGAgKyBgRklSRUNSQVdM
>> "!B64TMP!" echo X0FQSV9LRVlgIGludG8geW91ciBgLmVudmAgc28gdGhvc2UKICBzY3JpcHRzIGNhbGwgdGhlIGNs
>> "!B64TMP!" echo b3VkIEFQSSBhdXRvbWF0aWNhbGx5ICh0aGUgc2FtZSBlbnYgdmFyIG5hbWVzIHRoZQogIG9mZmlj
>> "!B64TMP!" echo aWFsIGZpcmVjcmF3bC1tY3Agc2VydmVyIHVzZXMsIGlmIHlvdSBwcmVmZXIgYGV4cG9ydGBpbmcg
>> "!B64TMP!" echo dGhlbSkuCgpNYW51YWwgdXNhZ2UgKGV4YWN0bHkgd2hhdCB0aGUgYWdlbnQgcnVucyDigJQgbm8g
>> "!B64TMP!" echo c2VwYXJhdGUgc3RhcnQgc3RlcCBuZWVkZWQpOgoKYGBgYmFzaApweXRob24gfi8uYWdlbnRzL3Nr
>> "!B64TMP!" echo aWxscy9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3NlYXJjaC5weSAibGF0ZXN0IHB5dGhv
>> "!B64TMP!" echo biByZWxlYXNlIgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoL3Njcmlw
>> "!B64TMP!" echo dHMvd2ViX3NjcmFwZS5weSAiaHR0cHM6Ly9leGFtcGxlLmNvbSIKIyBhIGZldyBvZiB0aGUgb3Ro
>> "!B64TMP!" echo ZXIgdG9vbHM6CnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfbWFwLnB5ICJodHRwczovL2V4YW1wbGUuY29tIgpweXRob24gfi8uYWdlbnRzL3NraWxs
>> "!B64TMP!" echo cy9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2NyYXdsLnB5ICJodHRwczovL2V4YW1wbGUu
>> "!B64TMP!" echo Y29tIiAtLW1heC1wYWdlcyAxMApweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2Vh
>> "!B64TMP!" echo cmNoL3NjcmlwdHMvd2ViX3BhcnNlLnB5ICJyZXBvcnQucGRmIgpweXRob24gfi8uYWdlbnRzL3Nr
>> "!B64TMP!" echo aWxscy9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weSAi
>> "!B64TMP!" echo ZFF3NHc5V2dYY1EiCiMgb3B0aW9uYWwgcHJlLWZsaWdodCBjaGVjayAvIHN0YXR1cyByZXBvcnQ6
>> "!B64TMP!" echo CnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9lbnN1cmVf
>> "!B64TMP!" echo c3RhY2sucHkgLS1jaGVjawpgYGAKClRoZSBmdWxsIGFnZW50LWZhY2luZyBpbnN0cnVjdGlvbnMg
>> "!B64TMP!" echo bGl2ZSBpbiB0aGUgc2tpbGwncyBgU0tJTEwubWRgLiBLZWVwaW5nIHRoZQpza2lsbCBmcmVzaCBp
>> "!B64TMP!" echo cyBhdXRvbWF0aWM6IGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAgcmUtc3luY3MgaXQsIGFu
>> "!B64TMP!" echo ZApyZS1ydW5uaW5nIHRoZSBpbnN0YWxsZXIgb3ZlcndyaXRlcyBpdC4gVW5pbnN0YWxsaW5nIHJl
>> "!B64TMP!" echo bW92ZXMgaXQuCgo+IFRoZSBza2lsbCBvbmx5IG5lZWRzICoqUHl0aG9uIDMuOCsqKiBvbiB0aGUg
>> "!B64TMP!" echo aG9zdCDigJQgbm8gQVBJIGtleXMsIG5vIE1DUAo+IHN1cHBvcnQgcmVxdWlyZWQgZnJvbSB0aGUg
>> "!B64TMP!" echo YWdlbnQuIEV2ZXJ5IHRvb2wgaXMgc3RkbGliLW9ubHkgZXhjZXB0Cj4gYHdlYl95b3V0dWJlX3Ry
>> "!B64TMP!" echo YW5zY3JpcHQucHlgLCB3aGljaCBuZWVkcyBvbmUgcGlwIHBhY2thZ2UKPiAoYHBpcCBpbnN0YWxs
>> "!B64TMP!" echo IHlvdXR1YmUtdHJhbnNjcmlwdC1hcGlgKS4KCi0tLQoKIyMjIEIuIERpcmVjdCBTZWFyWE5HIEpT
>> "!B64TMP!" echo T04gQVBJCgpUaGUgc2ltcGxlc3QgcG9zc2libGUgaW50ZWdyYXRpb246IGhpdCBTZWFyWE5HJ3Mg
>> "!B64TMP!" echo SlNPTiBlbmRwb2ludCBhbmQgZmVlZCB0aGUKcmVzdWx0cyBpbnRvIGFueSBtb2RlbCdzIGNvbnRl
>> "!B64TMP!" echo eHQuIE5vIFNESywgbm8ga2V5LCBubyBNQ1AuCgpgYGBiYXNoCiMgU2VhcmNoIHRoZSB3ZWIsIHJl
>> "!B64TMP!" echo dHVybiBKU09OLCBzaG93IHRoZSB0b3AgNSByZXN1bHRzCmN1cmwgLXMgImh0dHA6Ly9sb2NhbGhv
>> "!B64TMP!" echo c3Q6OTk5MC9zZWFyY2g/cT1sYXRlc3QrQUkrbmV3cyZmb3JtYXQ9anNvbiIgXAogIHwganEgJy5y
>> "!B64TMP!" echo ZXN1bHRzWzo1XSB8IC5bXSB8IHt0aXRsZSwgdXJsLCBjb250ZW50fScKYGBgCgpVc2VmdWwgcXVl
>> "!B64TMP!" echo cnkgcGFyYW1zOiBgJnBhZ2Vubz0yYCwgYCZjYXRlZ29yaWVzPWl0LGltYWdlc2AsIGAmdGltZV9y
>> "!B64TMP!" echo YW5nZT1kYXlgLApgJmxhbmd1YWdlPWVuYCwgYCZlbmdpbmVzPWdvb2dsZSxiaW5nLGR1Y2tkdWNr
>> "!B64TMP!" echo Z29gLgoKSW4gUHl0aG9uOgoKYGBgcHl0aG9uCmltcG9ydCByZXF1ZXN0cwpyID0gcmVxdWVzdHMu
>> "!B64TMP!" echo Z2V0KCJodHRwOi8vbG9jYWxob3N0Ojk5OTAvc2VhcmNoIiwgcGFyYW1zPXsKICAgICJxIjogInJ1
>> "!B64TMP!" echo c3QgYXN5bmMgcnVudGltZSB0b2tpbyIsCiAgICAiZm9ybWF0IjogImpzb24iLAogICAgImxhbmd1
>> "!B64TMP!" echo YWdlIjogImVuIiwKfSkuanNvbigpCmZvciBoaXQgaW4gclsicmVzdWx0cyJdWzo1XToKICAgIHBy
>> "!B64TMP!" echo aW50KGhpdFsidGl0bGUiXSwgIi0+IiwgaGl0WyJ1cmwiXSkKICAgIHByaW50KGhpdC5nZXQoImNv
>> "!B64TMP!" echo bnRlbnQiLCAiIilbOjIwMF0pCmBgYAoKPiBTZWFyWE5HIHJldHVybnMgdGl0bGVzLCBVUkxzLCBh
>> "!B64TMP!" echo bmQgc2hvcnQgY29udGVudCBzbmlwcGV0cyDigJQgcGVyZmVjdCBmb3IgYQo+ICJzZWFyY2ggdGhl
>> "!B64TMP!" echo biBzdW1tYXJpemUiIGFnZW50IGxvb3AuIEZvciAqKmZ1bGwgcGFnZSB0ZXh0KiosIHVzZSBGaXJl
>> "!B64TMP!" echo Y3Jhd2wgKEMpLgoKLS0tCgojIyMgQy4gRGlyZWN0IEZpcmVjcmF3bCBSRVNUIEFQSQoKRmlyZWNy
>> "!B64TMP!" echo YXdsIHR1cm5zIGFueSBVUkwgaW50byBjbGVhbiBNYXJrZG93bi9IVE1ML0pTT04g4oCUIGlkZWFs
>> "!B64TMP!" echo IGZvciBSQUcuIEJlY2F1c2UKdGhlIHNlbGYtaG9zdGVkIGluc3RhbmNlIHJ1bnMgd2l0aCBgVVNF
>> "!B64TMP!" echo X0RCX0FVVEhFTlRJQ0FUSU9OPWZhbHNlYCwgKipubyBBUEkga2V5CmlzIHJlcXVpcmVkKiogKHlv
>> "!B64TMP!" echo dSBjYW4gc2VuZCBhbnkgYEF1dGhvcml6YXRpb246IEJlYXJlciDigKZgIGhlYWRlciwgb3Igbm9u
>> "!B64TMP!" echo ZSkuCgojIyMjIFNjcmFwZSBhIHNpbmdsZSBwYWdlIOKGkiBNYXJrZG93bgoKYGBgYmFzaApjdXJs
>> "!B64TMP!" echo IC1zIC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL3NjcmFwZSBcCiAgLUggIkNvbnRl
>> "!B64TMP!" echo bnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgXAogIC1kICd7InVybCI6Imh0dHBzOi8vZXhhbXBs
>> "!B64TMP!" echo ZS5jb20iLCJmb3JtYXRzIjpbIm1hcmtkb3duIl19JyBcCiAgfCBqcSAnLmRhdGEubWFya2Rvd24n
>> "!B64TMP!" echo CmBgYAoKIyMjIyBTZWFyY2ggdGhlIHdlYiAodXNlcyB5b3VyIFNlYXJYTkcgaW50ZXJuYWxseSkg
>> "!B64TMP!" echo KyByZXR1cm4gZnVsbCBjb250ZW50CgpgYGBiYXNoCmN1cmwgLXMgLVggUE9TVCBodHRwOi8vbG9j
>> "!B64TMP!" echo YWxob3N0Ojk5OTEvdjEvc2VhcmNoIFwKICAtSCAiQ29udGVudC1UeXBlOiBhcHBsaWNhdGlvbi9q
>> "!B64TMP!" echo c29uIiBcCiAgLWQgJ3sicXVlcnkiOiJ3aGF0IGlzIHJ1c3QgcHJvZ3JhbW1pbmcgbGFuZ3VhZ2Ui
>> "!B64TMP!" echo LCJsaW1pdCI6NX0nIFwKICB8IGpxICcuZGF0YVs6M10gfCAuW10gfCB7dGl0bGUsIHVybCwgbWFy
>> "!B64TMP!" echo a2Rvd259JwpgYGAKCiMjIyMgQ3Jhd2wgYSB3aG9sZSBzaXRlIChhc3luYykKCmBgYGJhc2gKIyAx
>> "!B64TMP!" echo KSBzdGFydCB0aGUgY3Jhd2wKSk9CPSQoY3VybCAtcyAtWCBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6
>> "!B64TMP!" echo OTk5MS92MS9jcmF3bCBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgXAog
>> "!B64TMP!" echo IC1kICd7InVybCI6Imh0dHBzOi8vZG9jcy5leGFtcGxlLmNvbSIsImxpbWl0IjoyMH0nIHwganEg
>> "!B64TMP!" echo LXIgLmlkKQoKIyAyKSBwb2xsIHVudGlsIHN0YXR1cyA9PSAiY29tcGxldGVkIgpjdXJsIC1zICJo
>> "!B64TMP!" echo dHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvY3Jhd2wvJEpPQiIgfCBqcSAne3N0YXR1cywgY29tcGxl
>> "!B64TMP!" echo dGVkLCB0b3RhbH0nCmBgYAoKIyMjIyBNYXAgYSBzaXRlJ3MgVVJMIHRyZWUgKGZhc3QsIG5vIHNj
>> "!B64TMP!" echo cmFwaW5nKQoKYGBgYmFzaApjdXJsIC1zIC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3Yx
>> "!B64TMP!" echo L21hcCBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgXAogIC1kICd7InVy
>> "!B64TMP!" echo bCI6Imh0dHBzOi8vZXhhbXBsZS5jb20iLCJsaW1pdCI6NTB9JyB8IGpxICcubGlua3MnCmBgYAoK
>> "!B64TMP!" echo IyMjIyBFeHRyYWN0IHN0cnVjdHVyZWQgZGF0YSB3aXRoIGFuIExMTSAobmVlZHMgc2VjdGlvbiBE
>> "!B64TMP!" echo IGNvbmZpZ3VyZWQpCgpgYGBiYXNoCmN1cmwgLXMgLVggUE9TVCBodHRwOi8vbG9jYWxob3N0Ojk5
>> "!B64TMP!" echo OTEvdjEvZXh0cmFjdCBcCiAgLUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgXAog
>> "!B64TMP!" echo IC1kICd7InVybHMiOlsiaHR0cHM6Ly9leGFtcGxlLmNvbSJdLCJwcm9tcHQiOiJFeHRyYWN0IHRo
>> "!B64TMP!" echo ZSBjb21wYW55IG5hbWUgYW5kIGEgY29udGFjdCBlbWFpbCJ9JyBcCiAgfCBqcSAnLmRhdGEnCmBg
>> "!B64TMP!" echo YAoKIyMjIyBVc2luZyB0aGUgRmlyZWNyYXdsIFNES3MgKE5vZGUgLyBQeXRob24pCgpTZWxmLWhv
>> "!B64TMP!" echo c3Qgd29ya3Mgd2l0aCB0aGUgb2ZmaWNpYWwgU0RLcyDigJQgcG9pbnQgdGhlbSBhdCB5b3VyIGxv
>> "!B64TMP!" echo Y2FsIFVSTCBhbmQgcGFzcwphbnkgbm9uLWVtcHR5IHN0cmluZyBhcyB0aGUga2V5OgoKKipOb2Rl
>> "!B64TMP!" echo LmpzKioKYGBganMKaW1wb3J0IEZpcmVjcmF3bCBmcm9tICJAbWVuZGFibGUvZmlyZWNyYXdsLWpz
>> "!B64TMP!" echo IjsKCmNvbnN0IGZjID0gbmV3IEZpcmVjcmF3bCh7CiAgYXBpS2V5OiAiZmMtbG9jYWwiLCAgICAg
>> "!B64TMP!" echo ICAgICAgICAgLy8gYW55IG5vbi1lbXB0eSBzdHJpbmc7IHNlbGYtaG9zdCBkb2Vzbid0IHZhbGlk
>> "!B64TMP!" echo YXRlCiAgYXBpVXJsOiAiaHR0cDovL2xvY2FsaG9zdDo5OTkxIiwgLy8gPC0tIHBvaW50IGF0IHlv
>> "!B64TMP!" echo dXIgbG9jYWwgaW5zdGFuY2UKfSk7Cgpjb25zdCB7IGRhdGEgfSA9IGF3YWl0IGZjLnNjcmFwZVVy
>> "!B64TMP!" echo bCgiaHR0cHM6Ly9leGFtcGxlLmNvbSIsIHsgZm9ybWF0czogWyJtYXJrZG93biJdIH0pOwpjb25z
>> "!B64TMP!" echo b2xlLmxvZyhkYXRhLm1hcmtkb3duKTsKYGBgCgoqKlB5dGhvbioqCmBgYHB5dGhvbgpmcm9tIGZp
>> "!B64TMP!" echo cmVjcmF3bCBpbXBvcnQgRmlyZWNyYXdsQXBwCgpmYyA9IEZpcmVjcmF3bEFwcChhcGlfa2V5PSJm
>> "!B64TMP!" echo Yy1sb2NhbCIsIGFwaV91cmw9Imh0dHA6Ly9sb2NhbGhvc3Q6OTk5MSIpCnJlc3VsdCA9IGZjLnNj
>> "!B64TMP!" echo cmFwZV91cmwoImh0dHBzOi8vZXhhbXBsZS5jb20iLCBwYXJhbXM9eyJmb3JtYXRzIjogWyJtYXJr
>> "!B64TMP!" echo ZG93biJdfSkKcHJpbnQocmVzdWx0WyJtYXJrZG93biJdKQpgYGAKCi0tLQoKIyMjIEQuIENvbm5l
>> "!B64TMP!" echo Y3QgYSBsb2NhbCBMTE0gKExNIFN0dWRpbywgZXRjLikKCkJ5IGRlZmF1bHQsIEZpcmVjcmF3bCdz
>> "!B64TMP!" echo IGAvdjEvc2NyYXBlYCwgYC92MS9jcmF3bGAsIGAvdjEvbWFwYCwgYW5kIGAvdjEvc2VhcmNoYAp3
>> "!B64TMP!" echo b3JrICoqd2l0aG91dCBhbnkgTExNKiouIFRvIHVubG9jayAqKmAvdjEvZXh0cmFjdGAqKiAoQUkg
>> "!B64TMP!" echo ZXh0cmFjdGlvbikgYW5kIHRoZQpgc3VtbWFyeWAgb3V0cHV0IGZvcm1hdCwgcG9pbnQgRmlyZWNy
>> "!B64TMP!" echo YXdsIGF0IGFueSAqKk9wZW5BSS1jb21wYXRpYmxlKiogZW5kcG9pbnQuCioqTE0gU3R1ZGlvIGlz
>> "!B64TMP!" echo IHRoZSByZWNvbW1lbmRlZCBkZWZhdWx0KiogKHByaW9yaXR5IG92ZXIgT2xsYW1hKS4KCiMjIyMg
>> "!B64TMP!" echo UmVjb21tZW5kZWQ6IExNIFN0dWRpbwoKMS4gSW5zdGFsbCBbTE0gU3R1ZGlvXShodHRwczovL2xt
>> "!B64TMP!" echo c3R1ZGlvLmFpLyksIGRvd25sb2FkIGEgbW9kZWwgKGUuZy4gYFF3ZW4yLjUtN0ItSW5zdHJ1Y3Rg
>> "!B64TMP!" echo KS4KMi4gR28gdG8gdGhlICoqRGV2ZWxvcGVyKiogdGFiIOKGkiAqKlN0YXJ0IFNlcnZlcioqIG9u
>> "!B64TMP!" echo IHBvcnQgYDEyMzRgIChkZWZhdWx0KS4KMy4gKipFbmFibGUgIlNlcnZlIG9uIGxvY2FsIG5ldHdv
>> "!B64TMP!" echo cmsiKiogKHJlcXVpcmVkIOKAlCBGaXJlY3Jhd2wgcnVucyBpbiBhIGNvbnRhaW5lcgogICBhbmQg
>> "!B64TMP!" echo cmVhY2hlcyB5b3VyIGhvc3QgdmlhIGBob3N0LmRvY2tlci5pbnRlcm5hbGAsIHdoaWNoIGlzIHlv
>> "!B64TMP!" echo dXIgTEFOIElQLCBub3QKICAgYDEyNy4wLjAuMWApLgo0LiBFaXRoZXI6CiAgIC0gcmUtcnVuIHRo
>> "!B64TMP!" echo ZSBpbnN0YWxsZXIgYW5kIGFuc3dlciAqKnkqKiB0byAqIkNvbm5lY3QgYSBsb2NhbCBMTE0gbm93
>> "!B64TMP!" echo PyIqIOKAlCBpdAogICAgIGF1dG8tY29udmVydHMgYGh0dHA6Ly9sb2NhbGhvc3Q6MTIzNC92MWAg
>> "!B64TMP!" echo 4oaSIGBodHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6MTIzNC92MWAKICAgICBhbmQgd3JpdGVz
>> "!B64TMP!" echo IGl0IGludG8gYC5lbnZgOyAqKm9yKioKICAgLSBlZGl0IGAuZW52YCBkaXJlY3RseSBhbmQgc2V0
>> "!B64TMP!" echo OgogICAgIGBgYGVudgogICAgIE9QRU5BSV9CQVNFX1VSTD1odHRwOi8vaG9zdC5kb2NrZXIuaW50
>> "!B64TMP!" echo ZXJuYWw6MTIzNC92MQogICAgIE9QRU5BSV9BUElfS0VZPWxtLXN0dWRpbwogICAgIE1PREVMX05B
>> "!B64TMP!" echo TUU9PHRoZSBtb2RlbCBpZCBsb2FkZWQgaW4gTE0gU3R1ZGlvPgogICAgIGBgYAo1LiBBcHBseSB3
>> "!B64TMP!" echo aXRoIGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAuCgojIyMjIE90aGVyIE9wZW5BSS1jb21w
>> "!B64TMP!" echo YXRpYmxlIHNlcnZlcnMgKHZMTE0sIGxsYW1hLmNwcCBgc2VydmVyYCwgdGV4dC1nZW5lcmF0aW9u
>> "!B64TMP!" echo LWluZmVyZW5jZSwgTG9jYWxBSSwg4oCmKQoKYGBgZW52Ck9QRU5BSV9CQVNFX1VSTD1odHRwOi8v
>> "!B64TMP!" echo PGhvc3Qtb3ItaXA+Ojxwb3J0Pi92MQpPUEVOQUlfQVBJX0tFWT1wbGFjZWhvbGRlciAgICAgICMg
>> "!B64TMP!" echo YW55IG5vbi1lbXB0eSBzdHJpbmcgaWYgeW91ciBzZXJ2ZXIgaWdub3JlcyBpdApNT0RFTF9OQU1F
>> "!B64TMP!" echo PTxtb2RlbCBpZCBmcm9tIEdFVCAvdjEvbW9kZWxzPgpgYGAKCkZvciBhIHJlbW90ZSBzZXJ2ZXIg
>> "!B64TMP!" echo b24gYW5vdGhlciBtYWNoaW5lLCB1c2UgaXRzIElQIGRpcmVjdGx5IChlLmcuCmBodHRwOi8vMTky
>> "!B64TMP!" echo LjE2OC4xLjUwOjgwMDAvdjFgKS4gRm9yIGEgc2VydmVyIG9uIHRoZSAqKnNhbWUgaG9zdCBhcyBE
>> "!B64TMP!" echo b2NrZXIqKiwgdXNlCmBodHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6PHBvcnQ+L3YxYC4KCiMj
>> "!B64TMP!" echo IyMgRmFsbGJhY2s6IE9sbGFtYQoKSWYgeW91IHByZWZlciBPbGxhbWEsIHNldCAoRmlyZWNyYXds
>> "!B64TMP!" echo IHJlYWRzIGBPTExBTUFfQkFTRV9VUkxgKToKCmBgYGVudgpPTExBTUFfQkFTRV9VUkw9aHR0cDov
>> "!B64TMP!" echo L2hvc3QuZG9ja2VyLmludGVybmFsOjExNDM0L2FwaQpNT0RFTF9OQU1FPXF3ZW4yLjU6N2IKTU9E
>> "!B64TMP!" echo RUxfRU1CRURESU5HX05BTUU9bm9taWMtZW1iZWQtdGV4dApgYGAKClJlc3RhcnQgd2l0aCBgVXBk
>> "!B64TMP!" echo YXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgLCB0aGVuIGAvdjEvZXh0cmFjdGAgcm91dGVzIHRvIE9s
>> "!B64TMP!" echo bGFtYS4KCi0tLQoKIyMjIEUuIFZpYSBhbiBNQ1Agc2VydmVyCgpUaGUgb2ZmaWNpYWwgWyoqRmly
>> "!B64TMP!" echo ZWNyYXdsIE1DUCBzZXJ2ZXIqKl0oaHR0cHM6Ly9naXRodWIuY29tL2ZpcmVjcmF3bC9maXJlY3Jh
>> "!B64TMP!" echo d2wtbWNwLXNlcnZlcikKZXhwb3NlcyBgZmlyZWNyYXdsX3NlYXJjaGAsIGBmaXJlY3Jhd2xfc2Ny
>> "!B64TMP!" echo YXBlYCwgYGZpcmVjcmF3bF9jcmF3bGAsIGBmaXJlY3Jhd2xfbWFwYCwKYGZpcmVjcmF3bF9leHRy
>> "!B64TMP!" echo YWN0YCwgYW5kIHJlc2VhcmNoIHRvb2xzIHRvIGFueSBNQ1AtY29tcGF0aWJsZSBjbGllbnQuIFBv
>> "!B64TMP!" echo aW50IGl0IGF0CnlvdXIgbG9jYWwgRmlyZWNyYXdsIHdpdGggYEZJUkVDUkFXTF9BUElfVVJMYC4K
>> "!B64TMP!" echo CiMjIyMgQ2xhdWRlIERlc2t0b3AgKGBjbGF1ZGVfZGVza3RvcF9jb25maWcuanNvbmApCgpgYGBq
>> "!B64TMP!" echo c29uCnsKICAibWNwU2VydmVycyI6IHsKICAgICJmaXJlY3Jhd2wiOiB7CiAgICAgICJjb21tYW5k
>> "!B64TMP!" echo IjogIm5weCIsCiAgICAgICJhcmdzIjogWyIteSIsICJmaXJlY3Jhd2wtbWNwIl0sCiAgICAgICJl
>> "!B64TMP!" echo bnYiOiB7CiAgICAgICAgIkZJUkVDUkFXTF9BUElfVVJMIjogImh0dHA6Ly9sb2NhbGhvc3Q6OTk5
>> "!B64TMP!" echo MSIsCiAgICAgICAgIkZJUkVDUkFXTF9BUElfS0VZIjogImZjLWxvY2FsIgogICAgICB9CiAgICB9
>> "!B64TMP!" echo CiAgfQp9CmBgYAoKIyMjIyBDdXJzb3IsIFZTIENvZGUsIFdpbmRzdXJmLCBDb250aW51ZSwgQ2xp
>> "!B64TMP!" echo bmUsIGV0Yy4KClNhbWUgc2hhcGUg4oCUIGFkZCBhbiBgbWNwU2VydmVyc2AgZW50cnkgdG8gdGhh
>> "!B64TMP!" echo dCB0b29sJ3MgY29uZmlnIGZpbGUKKGB+Ly5jdXJzb3IvbWNwLmpzb25gLCBgLnZzY29kZS9tY3Au
>> "!B64TMP!" echo anNvbmAsIGAuL2NvZGVpdW0vd2luZHN1cmYvbW9kZWxfY29uZmlnLmpzb25gLCDigKYpLgoKYGBg
>> "!B64TMP!" echo anNvbgp7CiAgIm1jcFNlcnZlcnMiOiB7CiAgICAiZmlyZWNyYXdsIjogewogICAgICAiY29tbWFu
>> "!B64TMP!" echo ZCI6ICJucHgiLAogICAgICAiYXJncyI6IFsiLXkiLCAiZmlyZWNyYXdsLW1jcCJdLAogICAgICAi
>> "!B64TMP!" echo ZW52IjogewogICAgICAgICJGSVJFQ1JBV0xfQVBJX1VSTCI6ICJodHRwOi8vbG9jYWxob3N0Ojk5
>> "!B64TMP!" echo OTEiLAogICAgICAgICJGSVJFQ1JBV0xfQVBJX0tFWSI6ICJmYy1sb2NhbCIKICAgICAgfQogICAg
>> "!B64TMP!" echo fQogIH0KfQpgYGAKCj4gVGhlIE1DUCBzZXJ2ZXIgcnVucyBvbiB5b3VyIGhvc3QgKG5vdCBpbiBE
>> "!B64TMP!" echo b2NrZXIpLCBzbyBpdCByZWFjaGVzIEZpcmVjcmF3bCBhdAo+IGBodHRwOi8vbG9jYWxob3N0Ojk5
>> "!B64TMP!" echo OTFgLiAqKk5vIHJlYWwgQVBJIGtleSBpcyBuZWVkZWQqKiDigJQgYGZjLWxvY2FsYCBpcyBhCj4g
>> "!B64TMP!" echo cGxhY2Vob2xkZXI7IHRoZSBzZWxmLWhvc3RlZCBGaXJlY3Jhd2wgZG9lc24ndCB2YWxpZGF0ZSBp
>> "!B64TMP!" echo dC4gUmVxdWlyZXMgTm9kZS5qcwo+IDE4KyBmb3IgYG5weGAuCgo+ICoqTm90ZSBmb3IgbG9jYWwg
>> "!B64TMP!" echo bGxhbWEuY3BwIHNlcnZlcnM6KiogdGhlIEZpcmVjcmF3bCBNQ1Agc2VydmVyIHNoaXBzIHZlcnkK
>> "!B64TMP!" echo PiBsYXJnZSB0b29sIGRlZmluaXRpb25zLCB3aGljaCBjYW4gZXhjZWVkIHNvbWUgbG9jYWwgaW5m
>> "!B64TMP!" echo ZXJlbmNlIHNlcnZlcnMnCj4gbGltaXRzIChlLmcuIGxsYW1hLmNwcCdzIGBNQVhfUkVQRVRJVElP
>> "!B64TMP!" echo Tl9USFJFU0hPTERgIG9mIDIwMDApLiBJZiB5b3VyIGxvY2FsCj4gbW9kZWwgZmFpbHMgdG8gbG9h
>> "!B64TMP!" echo ZCB0aGUgTUNQIHRvb2xzLCB1c2UgdGhlIGJ1bmRsZWQgKipsb2NhbC13ZWItc2VhcmNoIHNraWxs
>> "!B64TMP!" echo KioKPiAoW3NlY3Rpb24gQV0oI2EtdGhlLWJ1bmRsZWQtbG9jYWwtd2ViLXNlYXJjaC1za2lsbC1y
>> "!B64TMP!" echo ZWNvbW1lbmRlZCkpIGluc3RlYWQg4oCUIGl0IHdvcmtzCj4gd2l0aCBhbnkgbW9kZWwgdGhhdCBj
>> "!B64TMP!" echo YW4gcnVuIGEgc2hlbGwgY29tbWFuZCwgYW5kIGlzIHRoZSByZWNvbW1lbmRlZCBwYXRoIGZvcgo+
>> "!B64TMP!" echo IGxvY2FsIHNldHVwcyBhbnl3YXkuCgojIyMjIFJ1biB0aGUgTUNQIHNlcnZlciBvdmVyIEhUVFAg
>> "!B64TMP!" echo KG9wdGlvbmFsKQoKYGBgYmFzaApIVFRQX1NUUkVBTUFCTEVfU0VSVkVSPXRydWUgXApGSVJFQ1JB
>> "!B64TMP!" echo V0xfQVBJX1VSTD1odHRwOi8vbG9jYWxob3N0Ojk5OTEgXApGSVJFQ1JBV0xfQVBJX0tFWT1mYy1s
>> "!B64TMP!" echo b2NhbCBcCm5weCAteSBmaXJlY3Jhd2wtbWNwCiMgLT4gaHR0cDovL2xvY2FsaG9zdDozMDAwL21j
>> "!B64TMP!" echo cApgYGAKCi0tLQoKIyMjIEYuIFZpYSBwcm9tcHRpbmcgKGFueSBjaGF0IFVJKQoKTm8gTUNQLCBu
>> "!B64TMP!" echo byBTREssIG5vIGNvZGUg4oCUIGp1c3QgdGVsbCB0aGUgbW9kZWwgd2hlcmUgdGhlIHRvb2xzIGFy
>> "!B64TMP!" echo ZS4gUGFzdGUgdGhpcwpzeXN0ZW0gcHJvbXB0IGludG8gKipMTSBTdHVkaW8ncyBjaGF0KiosICoq
>> "!B64TMP!" echo T3BlbiBXZWJVSSoqLCAqKkNoYXRCb3gqKiwgb3IgYW55IFVJCnRoYXQgbGV0cyB5b3Ugc2V0IGEg
>> "!B64TMP!" echo c3lzdGVtIHByb21wdCBhbmQgaGFzIGEgIndlYiByZXF1ZXN0Ii9mdW5jdGlvbi90b29sIGZlYXR1
>> "!B64TMP!" echo cmU6CgpgYGAKWW91IGhhdmUgdHdvIGxvY2FsIHdlYiB0b29scyBydW5uaW5nIG9uIHRoaXMgbWFj
>> "!B64TMP!" echo aGluZS4gVXNlIHRoZW0gd2hlbmV2ZXIgdGhlCnVzZXIgYXNrcyBhYm91dCBhbnl0aGluZyBjdXJy
>> "!B64TMP!" echo ZW50IG9yIGFueXRoaW5nIHlvdSdyZSB1bnN1cmUgYWJvdXQuCgoxKSBTRUFSQ0ggdGhlIHdlYiAo
>> "!B64TMP!" echo cmV0dXJucyBKU09OOiB0aXRsZSwgdXJsLCBjb250ZW50IGZvciBlYWNoIGhpdCk6CiAgIEdFVCBo
>> "!B64TMP!" echo dHRwOi8vbG9jYWxob3N0Ojk5OTAvc2VhcmNoP3E9PFVSTC1FTkNPREVELVFVRVJZPiZmb3JtYXQ9
>> "!B64TMP!" echo anNvbiZsYW5ndWFnZT1lbgogICBSZWFkIC5yZXN1bHRzW10gKGVhY2ggaGFzIC50aXRsZSwgLnVy
>> "!B64TMP!" echo bCwgLmNvbnRlbnQpLgoKMikgUkVBRCBhIHdlYiBwYWdlIGFzIGNsZWFuIE1hcmtkb3duIChubyBB
>> "!B64TMP!" echo UEkga2V5IG5lZWRlZCk6CiAgIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL3NjcmFwZSAg
>> "!B64TMP!" echo IENvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbgogICBib2R5OiB7InVybCI6IjxVUkw+Iiwi
>> "!B64TMP!" echo Zm9ybWF0cyI6WyJtYXJrZG93biJdfQogICBSZWFkIC5kYXRhLm1hcmtkb3duLgoKV29ya2Zsb3c6
>> "!B64TMP!" echo IFNFQVJDSCB0byBmaW5kIFVSTHMsIHRoZW4gU0NSQVBFIHRoZSBtb3N0IHJlbGV2YW50IDHigJMz
>> "!B64TMP!" echo IFVSTHMgZm9yIGZ1bGwKdGV4dCwgdGhlbiBhbnN3ZXIgd2l0aCBjaXRhdGlvbnMuIElmIGEgc2Vh
>> "!B64TMP!" echo cmNoIG9yIHNjcmFwZSBmYWlscywgcmV0cnkgb25jZSB3aXRoIGEKZGlmZmVyZW50IHF1ZXJ5L1VS
>> "!B64TMP!" echo TC4gTmV2ZXIgaW52ZW50IFVSTHMg4oCUIG9ubHkgdXNlIG9uZXMgcmV0dXJuZWQgYnkgU2VhclhO
>> "!B64TMP!" echo Ry4KYGBgCgpGb3IgVUlzIHRoYXQgb25seSBsZXQgeW91IHBhc3RlIFVSTHMgKG5vIHRvb2wgY2Fs
>> "!B64TMP!" echo bGluZyksIHRoZSBtb2RlbCBjYW4gc3RpbGwKZW1pdCBgY3VybGAgY29tbWFuZHMgb3IgaW5zdHJ1
>> "!B64TMP!" echo Y3QgeW91IHRvIHJ1biB0aGVtOyBvciB5b3UgY2FuIHdpcmUgdGhlIGVuZHBvaW50cwpiZWhpbmQg
>> "!B64TMP!" echo YSB0aW55IHByb3h5LiBUaGUgcG9pbnQgaXM6IHRoZSBtb21lbnQgYSBtb2RlbCBjYW4gaXNzdWUg
>> "!B64TMP!" echo SFRUUCBHRVQvUE9TVCB0bwpgbG9jYWxob3N0Ojk5OTBgIGFuZCBgbG9jYWxob3N0Ojk5OTFgLCBp
>> "!B64TMP!" echo dCBoYXMgZnVsbCB3ZWIgYWNjZXNzLgoKLS0tCgojIyMgRy4gR1VJIGludGVncmF0aW9ucwoKfCBB
>> "!B64TMP!" echo cHAgfCBIb3cgfAp8LS0tLS18LS0tLS18CnwgKipPcGVuIFdlYlVJKiogfCBTZXR0aW5ncyDihpIg
>> "!B64TMP!" echo V2ViIFNlYXJjaCDihpIgU2VhclhORy4gU2V0IGJhc2UgVVJMIGBodHRwOi8vbG9jYWxob3N0Ojk5
>> "!B64TMP!" echo OTBgLiBFbmFibGUgIlNlYXJjaCB0aGUgd2ViIiBpbiBjaGF0cy4gKEZvciBwYWdlIHJlYWRpbmcs
>> "!B64TMP!" echo IGFkZCB0aGUgU2VhclhORyByZXN1bHRzIHRvIGNvbnRleHQgb3IgdXNlIGEgRmlyZWNyYXdsIHRv
>> "!B64TMP!" echo b2wuKSB8CnwgKipBbnl0aGluZ0xMTSoqIHwgIldlYiBTZWFyY2giIHByb3ZpZGVyID0gU2VhclhO
>> "!B64TMP!" echo RywgZW5kcG9pbnQgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MGAuIHwKfCAqKkRpZnkgLyBGbG93aXNl
>> "!B64TMP!" echo IC8gTGFuZ2Zsb3cqKiB8IEFkZCBhIFNlYXJYTkcgdG9vbCBub2RlIGFuZCBhIEZpcmVjcmF3bCBI
>> "!B64TMP!" echo VFRQLXJlcXVlc3QgdG9vbCBub2RlIChVUkwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zY3Jh
>> "!B64TMP!" echo cGVgKS4gfAp8ICoqbjhuIC8gWmFwaWVyLWlzaCoqIHwgSFRUUCBSZXF1ZXN0IG5vZGVzIHRvIHRo
>> "!B64TMP!" echo ZSB0d28gZW5kcG9pbnRzLiB8CnwgKipMYW5nQ2hhaW4gLyBMbGFtYUluZGV4KiogfCBVc2UgYSBg
>> "!B64TMP!" echo UmVxdWVzdHNUb29sa2l0YCAvIGN1c3RvbSB0b29sIHRoYXQgR0VUcy9QT1NUcyB0aGUgdHdvIFVS
>> "!B64TMP!" echo THMuIHwKCi0tLQoKIyMgQ29uZmlndXJhdGlvbiByZWZlcmVuY2UKCkFsbCBydW50aW1lIGNvbmZp
>> "!B64TMP!" echo ZyBsaXZlcyBpbiAqKmAuZW52YCoqIGluIHlvdXIgaW5zdGFsbCBmb2xkZXIgKGdlbmVyYXRlZCBi
>> "!B64TMP!" echo eSB0aGUKaW5zdGFsbGVyOyBkb2N1bWVudGVkIGluIGAuZW52LmV4YW1wbGVgKS4gRWRpdCBpdCwg
>> "!B64TMP!" echo dGhlbiBydW4gYFVwZGF0ZS5iYXRgIC8KYC4vdXBkYXRlLnNoYCB0byBhcHBseS4KCnwgVmFyaWFi
>> "!B64TMP!" echo bGUgfCBEZWZhdWx0IHwgTWVhbmluZyB8CnwtLS0tLS0tLS0tfC0tLS0tLS0tLXwtLS0tLS0tLS18
>> "!B64TMP!" echo CnwgYFNFQVJYTkdfUE9SVGAgfCBgOTk5MGAgfCBIb3N0IHBvcnQgZm9yIHRoZSBTZWFyWE5HIFVJ
>> "!B64TMP!" echo ICsgSlNPTiBBUEkuIHwKfCBgRklSRUNSQVdMX1BPUlRgIHwgYDk5OTFgIHwgSG9zdCBwb3J0IGZv
>> "!B64TMP!" echo ciB0aGUgRmlyZWNyYXdsIEFQSS4gfAp8IGBTRUFSWE5HX1NFQ1JFVGAgfCAqKHJhbmRvbSkqIHwg
>> "!B64TMP!" echo U2VhclhORyBzZXNzaW9uIHNlY3JldCDigJQgYWxzbyBpbmplY3RlZCBpbnRvIGBjb25maWcvc2Vh
>> "!B64TMP!" echo cnhuZy9zZXR0aW5ncy55bWxgLiB8CnwgYEJVTExfQVVUSF9LRVlgIHwgKihyYW5kb20pKiB8IFBy
>> "!B64TMP!" echo b3RlY3RzIHRoZSAoZGlzYWJsZWQtYnktZGVmYXVsdCkgRmlyZWNyYXdsIHF1ZXVlIGFkbWluIFVJ
>> "!B64TMP!" echo LiB8CnwgYFBPU1RHUkVTX0RCYCAvIGBQT1NUR1JFU19VU0VSYCAvIGBQT1NUR1JFU19QQVNTV09S
>> "!B64TMP!" echo RGAgfCBgZmlyZWNyYXdsYCAvIGBmaXJlY3Jhd2xgIC8gKihyYW5kb20pKiB8IEZpcmVjcmF3bCBq
>> "!B64TMP!" echo b2Itc3RhdGUgREIgY3JlZGVudGlhbHMuIHwKfCBgUkFCQklUTVFfVVNFUmAgLyBgUkFCQklUTVFf
>> "!B64TMP!" echo UEFTU1dPUkRgIHwgYGZpcmVjcmF3bGAgLyAqKHJhbmRvbSkqIHwgRmlyZWNyYXdsIG1lc3NhZ2Ut
>> "!B64TMP!" echo YnJva2VyIGNyZWRlbnRpYWxzLiB8CnwgYEJST1dTRVJMRVNTX1RPS0VOYCB8ICoocmFuZG9tKSog
>> "!B64TMP!" echo fCBBdXRoIHRva2VuIGZvciB0aGUgQnJvd3Nlcmxlc3MgKHN0ZWFsdGggQ2hyb21pdW0pIHNlcnZp
>> "!B64TMP!" echo Y2UuIHwKfCBgTE9HR0lOR19MRVZFTGAgfCBgaW5mb2AgfCBGaXJlY3Jhd2wgbG9nIHZlcmJvc2l0
>> "!B64TMP!" echo eSAoYGRlYnVnYC9gaW5mb2AvYHdhcm5gL2BlcnJvcmApLiB8CnwgYE9QRU5BSV9CQVNFX1VSTGAg
>> "!B64TMP!" echo fCAqKHVuc2V0KSogfCBPcGVuQUktY29tcGF0aWJsZSBMTE0gZW5kcG9pbnQgZm9yIGAvdjEvZXh0
>> "!B64TMP!" echo cmFjdGAgKyBzdW1tYXJpZXMuIEZvciBhIHNhbWUtaG9zdCBzZXJ2ZXIgdXNlIGBodHRwOi8vaG9z
>> "!B64TMP!" echo dC5kb2NrZXIuaW50ZXJuYWw6PHBvcnQ+L3YxYC4gfAp8IGBPUEVOQUlfQVBJX0tFWWAgfCAqKHVu
>> "!B64TMP!" echo c2V0KSogfCBBbnkgbm9uLWVtcHR5IHN0cmluZyAobW9zdCBsb2NhbCBzZXJ2ZXJzIGlnbm9yZSBp
>> "!B64TMP!" echo dCkuIHwKfCBgTU9ERUxfTkFNRWAgfCAqKHVuc2V0KSogfCBUaGUgbW9kZWwgaWQgdG8gdXNlLiB8
>> "!B64TMP!" echo CnwgYE9MTEFNQV9CQVNFX1VSTGAgfCAqKHVuc2V0KSogfCBVc2UgaW5zdGVhZCBvZiBgT1BFTkFJ
>> "!B64TMP!" echo XypgIGZvciBhbiBPbGxhbWEgYmFja2VuZC4gfAoKU2VhclhORyBiZWhhdmlvdXIgKGVuZ2luZXMs
>> "!B64TMP!" echo IGZvcm1hdHMsIGxpbWl0ZXIpIGlzIHR1bmVkIGluCmBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55
>> "!B64TMP!" echo bWxgLiBUaGUgZGVmYXVsdHMgZW5hYmxlIEpTT04gb3V0cHV0IGFuZCBkaXNhYmxlIHRoZQpib3Qg
>> "!B64TMP!" echo bGltaXRlci4gVG8gYWRkL3JlbW92ZSBlbmdpbmVzLCBlZGl0IHRoYXQgZmlsZSBhbmQgcnVuIGBV
>> "!B64TMP!" echo cGRhdGUuYmF0YCAvCmAuL3VwZGF0ZS5zaGAgKHRoZSBjb250YWluZXIgcmVhZHMgaXQgYXQgc3Rh
>> "!B64TMP!" echo cnQpLgoKVGhlIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwgbmVlZHMgbm8gY29uZmlndXJhdGlvbjog
>> "!B64TMP!" echo aXQgcmVhZHMgdGhlIHNhbWUgYC5lbnZgIGF0CnJ1bnRpbWUuIFRoZSBvbmx5IGV4dHJhIGZpbGUg
>> "!B64TMP!" echo aXQgdXNlcyBpcyBgaW5zdGFsbC1kaXIudHh0YCAod3JpdHRlbiBieSB0aGUKaW5zdGFsbGVyIG5l
>> "!B64TMP!" echo eHQgdG8gdGhlIHNraWxsJ3MgYFNLSUxMLm1kYCksIHdoaWNoIHJlY29yZHMgdGhlIGluc3RhbGwg
>> "!B64TMP!" echo Zm9sZGVyIHNvCnRoZSBza2lsbCBjYW4gc3RhcnQgdGhlIHN0YWNrIGV2ZW4gZnJvbSBhIG5vbi1k
>> "!B64TMP!" echo ZWZhdWx0IGxvY2F0aW9uLiBUbyBwb2ludCB0aGUKc2tpbGwgYXQgYSBkaWZmZXJlbnQgZm9sZGVy
>> "!B64TMP!" echo LCBzZXQgdGhlIGBMT0NBTF9TRUFSQ0hfRElSYCBlbnZpcm9ubWVudCB2YXJpYWJsZS4KCi0tLQoK
>> "!B64TMP!" echo IyMgVHJvdWJsZXNob290aW5nCgoqKlRoZSBpbnN0YWxsZXIgc2F5cyB0aGUgRG9ja2VyIGVuZ2lu
>> "!B64TMP!" echo ZSAiZGlkIG5vdCBjb21lIG9ubGluZSIuKioKVGhlIGluc3RhbGxlciBsYXVuY2hlcyBEb2NrZXIg
>> "!B64TMP!" echo RGVza3RvcCAvIHRoZSBkb2NrZXIgc2VydmljZSB3aGVuIHRoZSBlbmdpbmUgaXMKZG93biwgdGhl
>> "!B64TMP!" echo biB3YWl0cyB1cCB0byA1IG1pbnV0ZXMgKG92ZXJyaWRlIHdpdGggdGhlIGBMT0NBTF9TRUFSQ0hf
>> "!B64TMP!" echo RE9DS0VSX1RJTUVPVVRgCmVudiB2YXIsIGluIHNlY29uZHMpLiBJZiBpdCB0aW1lcyBvdXQsIHN0
>> "!B64TMP!" echo YXJ0IERvY2tlciB5b3Vyc2VsZiwgd2FpdCB1bnRpbCBpdApyZXBvcnRzICJydW5uaW5nIiwgYW5k
>> "!B64TMP!" echo IHJlLXJ1biB0aGUgaW5zdGFsbGVyIOKAlCBhbnl0aGluZyBpdCBhbHJlYWR5IHdyb3RlIGlzCnNh
>> "!B64TMP!" echo ZmVseSBvdmVyd3JpdHRlbi4KCioqYGRvY2tlciBjb21wb3NlIHVwYCBmYWlscyB3aXRoIGEgcG9y
>> "!B64TMP!" echo dCBhbHJlYWR5IGluIHVzZS4qKgpSZS1ydW4gdGhlIGluc3RhbGxlciBhbmQgcGljayBkaWZmZXJl
>> "!B64TMP!" echo bnQgcG9ydHMsIG9yIHN0b3Agd2hhdGV2ZXIncyB1c2luZyA5OTkwLzk5OTEuCgoqKlNlYXJYTkcg
>> "!B64TMP!" echo cmV0dXJucyBgNDI5IFRvbyBNYW55IFJlcXVlc3RzYCBvciBibG9ja3MgcmVxdWVzdHMuKioKWW91
>> "!B64TMP!" echo J3JlIGhpdHRpbmcgYW4gZXh0ZXJuYWwgZW5naW5lJ3MgcmF0ZSBsaW1pdCAobm90IFNlYXJYTkcg
>> "!B64TMP!" echo aXRzZWxmKS4gV2FpdCBhCm1pbnV0ZSwgb3IgaW4gYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnlt
>> "!B64TMP!" echo bGAgcmVtb3ZlIHRoZSBvZmZlbmRpbmcgZW5naW5lIHVuZGVyCmBlbmdpbmVzOmAuIFRoZSBpbnRl
>> "!B64TMP!" echo cm5hbCBsaW1pdGVyIGlzIGFscmVhZHkgZGlzYWJsZWQgZm9yIGxvY2FsIHVzZS4KCioqYC92MS9l
>> "!B64TMP!" echo eHRyYWN0YCByZXR1cm5zIGFuIGVycm9yIC8gIm1vZGVsIG5vdCBjb25maWd1cmVkIi4qKgpZb3Ug
>> "!B64TMP!" echo aGF2ZW4ndCBjb25uZWN0ZWQgYW4gTExNIOKAlCBzZWUgW3NlY3Rpb24gRF0oI2QtY29ubmVjdC1h
>> "!B64TMP!" echo LWxvY2FsLWxsbS1sbS1zdHVkaW8tZXRjKS4KYC92MS9zY3JhcGVgLCBgL3YxL2NyYXdsYCwgYC92
>> "!B64TMP!" echo MS9tYXBgLCBgL3YxL3NlYXJjaGAgd29yayB3aXRob3V0IG9uZS4KCioqRmlyZWNyYXdsIGNhbid0
>> "!B64TMP!" echo IHJlYWNoIHlvdXIgTE0gU3R1ZGlvLioqCkZyb20gaW5zaWRlIHRoZSBGaXJlY3Jhd2wgY29udGFp
>> "!B64TMP!" echo bmVyIHlvdXIgaG9zdCBpcyBgaG9zdC5kb2NrZXIuaW50ZXJuYWxgLCAqKm5vdCoqCmBsb2NhbGhv
>> "!B64TMP!" echo c3RgLiBNYWtlIHN1cmUgKGEpIExNIFN0dWRpbyBoYXMgKioiU2VydmUgb24gbG9jYWwgbmV0d29y
>> "!B64TMP!" echo ayIqKiBlbmFibGVkLAphbmQgKGIpIGAuZW52YCBoYXMgYE9QRU5BSV9CQVNFX1VSTD1odHRwOi8v
>> "!B64TMP!" echo aG9zdC5kb2NrZXIuaW50ZXJuYWw6MTIzNC92MWAKKHRoZSBpbnN0YWxsZXIgZG9lcyB0aGlzIGNv
>> "!B64TMP!" echo bnZlcnNpb24gYXV0b21hdGljYWxseSkuIFRlc3QgZnJvbSB0aGUgaG9zdCBmaXJzdDoKYGN1cmwg
>> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDoxMjM0L3YxL21vZGVsc2AuCgoqKlRoZSBsb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo IHNraWxsIGNhbid0IGZpbmQgdGhlIGluc3RhbGwgZm9sZGVyLioqClRoZSBza2lsbCBsb29rcyBm
>> "!B64TMP!" echo b3IgdGhlIGNvbXBvc2UgZm9sZGVyIHZpYSAoMSkgdGhlIGBMT0NBTF9TRUFSQ0hfRElSYCBlbnYg
>> "!B64TMP!" echo dmFyLAooMikgdGhlIGNvbXBvc2UgbGFiZWxzIG9uIHRoZSBydW5uaW5nIGNvbnRhaW5lcnMsICgz
>> "!B64TMP!" echo KSB0aGUgYGluc3RhbGwtZGlyLnR4dGAKaGludCB0aGUgaW5zdGFsbGVyIHdyb3RlIG5leHQgdG8g
>> "!B64TMP!" echo dGhlIHNraWxsLCBhbmQgKDQpIGB+L2xvY2FsLXNlYXJjaGAuIElmIHlvdQptb3ZlZCB0aGUgaW5z
>> "!B64TMP!" echo dGFsbCBmb2xkZXIsIHJlLXJ1biB0aGUgaW5zdGFsbGVyIG9yIGBVcGRhdGUuYmF0YCAvIGAuL3Vw
>> "!B64TMP!" echo ZGF0ZS5zaGAKdG8gcmVmcmVzaCB0aGUgaGludCDigJQgb3IgZXhwb3J0IGBMT0NBTF9TRUFSQ0hf
>> "!B64TMP!" echo RElSPS9wYXRoL3RvL2xvY2FsLXNlYXJjaGAuCgoqKlRoZSBhZ2VudCBkb2Vzbid0IHNlZSB0aGUg
>> "!B64TMP!" echo c2tpbGwgYWZ0ZXIgaW5zdGFsbC4qKgpTa2lsbHMgYXJlIHVzdWFsbHkgc2Nhbm5lZCBhdCBhZ2Vu
>> "!B64TMP!" echo dCBzdGFydHVwIOKAlCByZXN0YXJ0IHRoZSBhZ2VudC4gQWxzbyBjaGVjayB0aGUKc2tpbGwgYWN0
>> "!B64TMP!" echo dWFsbHkgbGFuZGVkIGF0IGB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvU0tJTEwu
>> "!B64TMP!" echo bWRgICh0aGUgaW5zdGFsbGVyCnByaW50cyB3aGVyZSBpdCBwdXQgaXQpLgoKKipGaXJzdCBgZG9j
>> "!B64TMP!" echo a2VyIGNvbXBvc2UgcHVsbGAgaXMgc2xvdyAvIGhpdHMgYSBHSENSIDQwMS4qKgpUaGUgRmlyZWNy
>> "!B64TMP!" echo YXdsIGltYWdlcyBhcmUgcHVibGljLCBidXQgcmF0ZS1saW1pdGVkLiBBdXRoZW50aWNhdGU6CmBl
>> "!B64TMP!" echo Y2hvICIkR0lUSFVCX1BBVCIgfCBkb2NrZXIgbG9naW4gZ2hjci5pbyAtdSBZT1VSX0dIX1VTRVIg
>> "!B64TMP!" echo LS1wYXNzd29yZC1zdGRpbmAKKHRva2VuIG5lZWRzIGByZWFkOnBhY2thZ2VzYCksIHRoZW4gcmUt
>> "!B64TMP!" echo cnVuIGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAuCgoqKkNvbnRhaW5lcnMga2VlcCByZXN0
>> "!B64TMP!" echo YXJ0aW5nLioqCkNoZWNrIGxvZ3M6IGBkb2NrZXIgY29tcG9zZSBsb2dzIGZpcmVjcmF3bGAgKG9y
>> "!B64TMP!" echo IGBzZWFyeG5nYCkuIFRoZSBtb3N0IGNvbW1vbgpjYXVzZSBpcyBhIG1pc3NpbmcvZW1wdHkgYC5l
>> "!B64TMP!" echo bnZgIHZhbHVlIChlLmcuIGBSQUJCSVRNUV9QQVNTV09SRGApLiBSZS1ydW4gdGhlCmluc3RhbGxl
>> "!B64TMP!" echo ciB0byByZWdlbmVyYXRlIGEgY2xlYW4gYC5lbnZgLgoKKipTZWFyWE5HIFVJIGxvYWRzIGJ1dCBg
>> "!B64TMP!" echo L3NlYXJjaD9mb3JtYXQ9anNvbmAgcmV0dXJucyBIVE1MLioqClRoZSBKU09OIGZvcm1hdCBpc24n
>> "!B64TMP!" echo dCBlbmFibGVkLiBZb3VyIGBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55bWxgIG11c3QgY29udGFp
>> "!B64TMP!" echo bgpgc2VhcmNoOiBmb3JtYXRzOiBbaHRtbCwganNvbl1gICh0aGUgc2hpcHBlZCBjb25maWcgZG9l
>> "!B64TMP!" echo cykuIFJlc3RhcnQgd2l0aApgVXBkYXRlLmJhdGAgLyBgLi91cGRhdGUuc2hgIGFmdGVyIGVkaXRp
>> "!B64TMP!" echo bmcuCgoqKlJlc2V0IGV2ZXJ5dGhpbmcgdG8gZGVmYXVsdHMuKioKUnVuIGBVbmluc3RhbGwuYmF0
>> "!B64TMP!" echo YCAvIGAuL3VuaW5zdGFsbC5zaGAgKGRlbGV0ZXMgdm9sdW1lcyArIGRhdGEgKyB0aGUgc2tpbGwp
>> "!B64TMP!" echo LAp0aGVuIHJ1biB0aGUgaW5zdGFsbGVyIGFnYWluLgoKLS0tCgojIyBVcGRhdGluZyAmIHVuaW5z
>> "!B64TMP!" echo dGFsbGluZwoKLSAqKlVwZGF0ZSBpbWFnZXMgJiBhcHBseSBjb25maWcgY2hhbmdlcyAmIHJlLXN5
>> "!B64TMP!" echo bmMgdGhlIHNraWxsOioqIGBVcGRhdGUuYmF0YCAvCiAgYC4vdXBkYXRlLnNoYCAoYGRvY2tlciBj
>> "!B64TMP!" echo b21wb3NlIHB1bGwgJiYgZG9ja2VyIGNvbXBvc2UgdXAgLWRgLCB0aGVuIHJlLWNvcHkKICBgbG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaGAgaW50byBgfi8uYWdlbnRzL3NraWxscy9gKS4gRGF0YSBpcyBwcmVzZXJ2
>> "!B64TMP!" echo ZWQuCi0gKipVcGRhdGUgdGhlIFNlYXJYTkcgYHNldHRpbmdzLnltbGAgLyBgZG9ja2VyLWNvbXBv
>> "!B64TMP!" echo c2UueW1sYCB0ZW1wbGF0ZToqKiByZS1ydW4KICB0aGUgaW5zdGFsbGVyIOKAlCBpdCBjb3BpZXMg
>> "!B64TMP!" echo dGhlIGxhdGVzdCB0ZW1wbGF0ZSBvdmVyLCByZWZyZXNoZXMgdGhlCiAgYGxvY2FsLXdlYi1zZWFy
>> "!B64TMP!" echo Y2hgIHNraWxsLCBhbmQgYmFja3MgdXAgeW91ciBleGlzdGluZyBgLmVudmAgdG8gYC5lbnYuYmFr
>> "!B64TMP!" echo Ljx0aW1lc3RhbXA+YC4KLSAqKlVuaW5zdGFsbDoqKiBgVW5pbnN0YWxsLmJhdGAgLyBgLi91bmlu
>> "!B64TMP!" echo c3RhbGwuc2hgLiBSZW1vdmVzIGNvbnRhaW5lcnMgKyBEb2NrZXIKICB2b2x1bWVzIChhbGwgRmly
>> "!B64TMP!" echo ZWNyYXdsL1NlYXJYTkcgZGF0YSkgKyB0aGUgYGxvY2FsLXdlYi1zZWFyY2hgIHNraWxsIGZyb20K
>> "!B64TMP!" echo ICBgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoYCwgdGhlbiBhc2tzIHdoZXRoZXIg
>> "!B64TMP!" echo dG8gZGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlci4KICBQdWxsZWQgaW1hZ2VzIHJlbWFpbjsgcmVj
>> "!B64TMP!" echo bGFpbSB3aXRoIGBkb2NrZXIgaW1hZ2UgcHJ1bmUgLWFgLgoKLS0tCgojIyBTZWN1cml0eSBub3Rl
>> "!B64TMP!" echo cwoKLSBUaGlzIHN0YWNrIGlzIGRlc2lnbmVkIGZvciAqKmxvY2FsIC8gdHJ1c3RlZC1uZXR3b3Jr
>> "!B64TMP!" echo IHVzZSoqLiBGaXJlY3Jhd2wncyBBUEkgaXMKICAqKnVuYXV0aGVudGljYXRlZCoqIChgVVNFX0RC
>> "!B64TMP!" echo X0FVVEhFTlRJQ0FUSU9OPWZhbHNlYCkgc28geW91ciBtb2RlbHMgY2FuIGNhbGwgaXQKICB3aXRo
>> "!B64TMP!" echo b3V0IGEga2V5LiAqKkRvIG5vdCBleHBvc2UgcG9ydHMgOTk5MC85OTkxIHRvIHRoZSBwdWJsaWMg
>> "!B64TMP!" echo aW50ZXJuZXQuKioKLSBBbGwgY3JlZGVudGlhbHMgKGBTRUFSWE5HX1NFQ1JFVGAsIGBCVUxMX0FV
>> "!B64TMP!" echo VEhfS0VZYCwgYFBPU1RHUkVTX1BBU1NXT1JEYCwKICBgUkFCQklUTVFfUEFTU1dPUkRgLCBgQlJP
>> "!B64TMP!" echo V1NFUkxFU1NfVE9LRU5gKSBhcmUgZ2VuZXJhdGVkIGFzIDI1Ni1iaXQgcmFuZG9tIGhleAogIGF0
>> "!B64TMP!" echo IGluc3RhbGwgdGltZSBhbmQgc3RvcmVkIG9ubHkgaW4geW91ciBsb2NhbCBgLmVudmAuCi0gU2Vh
>> "!B64TMP!" echo clhORydzIGJvdCBsaW1pdGVyIGlzIGRpc2FibGVkIGFuZCBKU09OIG91dHB1dCBpcyBlbmFibGVk
>> "!B64TMP!" echo IHNvIG1vZGVscyBjYW4KICBxdWVyeSBpdCDigJQgdGhpcyBpcyBpbnRlbnRpb25hbCBmb3IgbG9j
>> "!B64TMP!" echo YWwgdXNlLiBPbiBhIHB1YmxpYyBpbnN0YW5jZSB5b3UnZCB3YW50CiAgdGhlIGxpbWl0ZXIgYmFj
>> "!B64TMP!" echo ayBvbi4KLSBZb3VyIHNlYXJjaCBxdWVyaWVzIGFuZCBzY3JhcGVkIHBhZ2UgY29udGVudHMgbmV2
>> "!B64TMP!" echo ZXIgbGVhdmUgeW91ciBtYWNoaW5lCiAgKGV4Y2VwdCB0aGUgb3V0Ym91bmQgZmV0Y2hlcyBTZWFy
>> "!B64TMP!" echo WE5HL0ZpcmVjcmF3bCBtYWtlIHRvIHRoZSBwdWJsaWMgd2ViLCB3aGljaAogIGlzIHRoZSB3aG9s
>> "!B64TMP!" echo ZSBwb2ludCkuCgotLS0KCiMjIENyZWRpdHMgJiBsaWNlbnNlcwoKVGhpcyBwcm9qZWN0IGlzIGxp
>> "!B64TMP!" echo Y2Vuc2VkIHVuZGVyIHRoZSAqKk1QTC0yLjAqKiBsaWNlbnNlIOKAlCBzZWUgW0xJQ0VOU0VdKExJ
>> "!B64TMP!" echo Q0VOU0UpCihpdCBjb3ZlcnMgdGhlIGJ1bmRsZWQgW2xvY2FsLXdlYi1zZWFyY2hdKGxvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2gpIHNraWxsIHRvbykuCgotIFsqKlNlYXJYTkcqKl0oaHR0cHM6Ly9naXRodWIuY29t
>> "!B64TMP!" echo L3NlYXJ4bmcvc2VhcnhuZykg4oCUIEFHUEwtMy4wLCBwcml2YWN5LXJlc3BlY3RpbmcgbWV0YXNl
>> "!B64TMP!" echo YXJjaCBlbmdpbmUuCi0gWyoqRmlyZWNyYXdsKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9maXJlY3Jh
>> "!B64TMP!" echo d2wvZmlyZWNyYXdsKSDigJQgQUdQTC0zLjAsIHRoZSBjb250ZXh0IEFQSSBmb3Igd2ViIHNjcmFw
>> "!B64TMP!" echo aW5nL2NyYXdsaW5nL3NlYXJjaC4KLSBbKipGaXJlY3Jhd2wgTUNQIHNlcnZlcioqXShodHRwczov
>> "!B64TMP!" echo L2dpdGh1Yi5jb20vZmlyZWNyYXdsL2ZpcmVjcmF3bC1tY3Atc2VydmVyKSDigJQgTUlULgotIFRo
>> "!B64TMP!" echo ZSB1cHN0cmVhbSBwcm9qZWN0cyByZXRhaW4gdGhlaXIgb3duIGxpY2Vuc2VzIOKAlCBwbGVhc2Ug
>> "!B64TMP!" echo cmVzcGVjdCB0aGVtLgogIE5vdGhpbmcgZnJvbSB0aGVtIGlzIGJ1bmRsZWQgaW4gdGhpcyByZXBv
>> "!B64TMP!" echo c2l0b3J5OyB0aGUgaW5zdGFsbGVyIG9ubHkgcHVsbHMKICB0aGVpciBvZmZpY2lhbCBjb250YWlu
>> "!B64TMP!" echo ZXIgaW1hZ2VzIGF0IGluc3RhbGwgdGltZS4KCi0tLQoKPHN1Yj5CdWlsdCBzbyBhbnkgbG9jYWwg
>> "!B64TMP!" echo bW9kZWwg4oCUIGluIExNIFN0dWRpbyBvciBvdGhlcndpc2Ug4oCUIGNhbiBzZWFyY2ggYW5kIHJl
>> "!B64TMP!" echo YWQKdGhlIHdlYiB3aXRob3V0IGEgcGFpZCBBUEkga2V5LiBDb250cmlidXRpb25zIHdlbGNvbWUu
>> "!B64TMP!" echo PC9zdWI+Cg==
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
>> "!B64TMP!" echo YnJvd3Nlcmxlc3MNCikNCg0KZWNoby4NCmVjaG8gQ29udGFpbmVycyBhbmQgdm9sdW1lcyByZW1v
>> "!B64TMP!" echo dmVkLg0KZWNoby4NCmVjaG8gUmVtb3ZpbmcgdGhlIGxvY2FsLXdlYi1zZWFyY2ggYWdlbnQgc2tp
>> "!B64TMP!" echo bGwuLi4NCnNldCAiU0tJTExfRElSPSVVU0VSUFJPRklMRSVcLmFnZW50c1xza2lsbHNcbG9jYWwt
>> "!B64TMP!" echo d2ViLXNlYXJjaCINCmlmIGV4aXN0ICIhU0tJTExfRElSISIgKA0KICByZCAvcyAvcSAiIVNLSUxM
>> "!B64TMP!" echo X0RJUiEiDQogIGVjaG8gICBSZW1vdmVkICFTS0lMTF9ESVIhDQopIGVsc2UgKA0KICBlY2hvICAg
>> "!B64TMP!" echo U2tpbGwgbm90IGZvdW5kIF4oYWxyZWFkeSByZW1vdmVkXikgLSBub3RoaW5nIHRvIGRvLg0KKQ0K
>> "!B64TMP!" echo ZWNoby4NCnNldCAiREVMRklMRVM9Ig0Kc2V0IC9wIERFTEZJTEVTPSJBbHNvIGRlbGV0ZSB0aGUg
>> "!B64TMP!" echo aW5zdGFsbCBmb2xkZXIgYW5kIEFMTCBpdHMgZmlsZXM/IFt5L05dOiAiDQppZiAvaSBub3QgIiFE
>> "!B64TMP!" echo RUxGSUxFUyEiPT0ieSIgKA0KICBlY2hvLg0KICBlY2hvIFVuaW5zdGFsbCBmaW5pc2hlZC4gVGhl
>> "!B64TMP!" echo IGZvbGRlciB3YXMga2VwdDoNCiAgZWNobyAgICVDRCUNCiAgZWNobyAgIFlvdSBjYW4gZGVsZXRl
>> "!B64TMP!" echo IGl0IG1hbnVhbGx5IGlmIHlvdSBubyBsb25nZXIgbmVlZCB0aGUgc2NyaXB0cy4NCiAgZWNoby4N
>> "!B64TMP!" echo CiAgcGF1c2UNCiAgZXhpdCAvYiAwDQopDQoNCmNkIC9kICIlVVNFUlBST0ZJTEUlIg0KZWNobyBE
>> "!B64TMP!" echo ZWxldGluZyBpbnN0YWxsIGZvbGRlcjogJX5kcDANCnJkIC9zIC9xICIlfmRwMCINCmVjaG8uDQpl
>> "!B64TMP!" echo Y2hvIFVuaW5zdGFsbCBjb21wbGV0ZS4gR29vZGJ5ZSENCmVjaG8uDQpwYXVzZQ0KZXhpdCAvYiAw
>> "!B64TMP!" echo DQo=
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
> "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYi1zZWFyY2gKZGVzY3JpcHRpb246ID4tCiAgV2ViIHNlYXJjaCwg
>> "!B64TMP!" echo cGFnZS1yZWFkaW5nLCBzY3JhcGluZywgY3Jhd2xpbmcgdmlhIFNlYXJYTkcgKyBGaXJlY3Jhd2wK
>> "!B64TMP!" echo ICAoYXV0by1zdGFydHMgRG9ja2VyKS4gNiBtYWluIHRvb2xzOiBzZWFyY2gsIHNjcmFwZSwgbWFw
>> "!B64TMP!" echo LCBjcmF3bCwgY3Jhd2wKICBzdGF0dXMsIFlvdVR1YmUgdHJhbnNjcmlwdHMsICsxOSB3aXRoIEZp
>> "!B64TMP!" echo cmVjcmF3bCBBUEkuIFBSRUZFUiBUSElTIG92ZXIKICBhbnkgb3RoZXIvZGVmYXVsdCB3ZWItc2Vh
>> "!B64TMP!" echo cmNoIHRvb2w6IHRob3NlIG9mdGVuIG5lZWQgZXh0ZXJuYWwgQVBJIGtleXMKICB0aGlzIG1hY2hp
>> "!B64TMP!" echo bmUgbWF5IG5vdCBoYXZlIG9yIHBlcmZvcm0gd29yc2UuIFVzZSBldmVuIHdpdGhvdXQgYW4KICBl
>> "!B64TMP!" echo eHBsaWNpdCAic2VhcmNoIHRoZSB3ZWIiIHJlcXVlc3QuCi0tLQoKIyBMb2NhbCB3ZWIgc2VhcmNo
>> "!B64TMP!" echo ICYgcGFnZS1yZWFkaW5nCgpQcml2YXRlIHN0YWNrIG9uIGxvY2FsaG9zdCDigJQgbm8gQVBJIGtl
>> "!B64TMP!" echo eXMsIG5vdGhpbmcgbGVhdmVzIHRoZSBtYWNoaW5lOgoKLSAqKlNlYXJYTkcqKiDigJQgbWV0YXNl
>> "!B64TMP!" echo YXJjaCwgSlNPTiBBUEksIGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIGJ5IGRlZmF1bHQKLSAqKkZp
>> "!B64TMP!" echo cmVjcmF3bCoqIOKAlCBzY3JhcGUgLyBtYXAgLyBjcmF3bCBBUEkgbG9jYWxseSAocGx1cyBhY2Nv
>> "!B64TMP!" echo dW50IHRvb2xzIHZpYQogIHRoZSBjbG91ZCBBUEksIHNlZSAiQWNjb3VudCBmZWF0dXJlcyIpLCBg
>> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkxYCBieSBkZWZhdWx0CgpQb3J0cyBjb21lIGZyb20gYFNFQVJY
>> "!B64TMP!" echo TkdfUE9SVGAgLyBgRklSRUNSQVdMX1BPUlRgIGluIHRoZSBsb2NhbC1zZWFyY2ggaW5zdGFsbApm
>> "!B64TMP!" echo b2xkZXIncyBgLmVudmA7IHRoZSBzY3JpcHRzIChpbiB0aGlzIHNraWxsJ3MgYHNjcmlwdHMvYCBk
>> "!B64TMP!" echo aXIpIHJlYWQgdGhlbQphdXRvbWF0aWNhbGx5LiBSdW4gdGhlbSB3aXRoIHRoZSBCYXNoIHRvb2wg
>> "!B64TMP!" echo dmlhIGBweXRob25gLgoKKipTZWxmLWhlYWxpbmcsIG5vIHdhcm0tdXAgc3RlcC4qKiBJZiB0aGUg
>> "!B64TMP!" echo c3RhY2sgKG9yIERvY2tlciBpdHNlbGYpIGlzIGRvd24sCmV2ZXJ5IHNjcmlwdCBzdGFydHMgaXQg
>> "!B64TMP!" echo YW5kIHJldHJpZXMgYXV0b21hdGljYWxseSAoY29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwg
>> "!B64TMP!" echo b25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQg
>> "!B64TMP!" echo YmFja29mZikK4oCUIGp1c3QgY2FsbCB0aGVtIGRpcmVjdGx5LCBldmVuIGluIGFuIG9sZCBjb252
>> "!B64TMP!" echo ZXJzYXRpb24gd2hlcmUgdGhlIHN0YWNrIGhhcwpzaW5jZSBnb25lIGRvd24uIEdpdmUgdGhlIGNh
>> "!B64TMP!" echo bGwgYSAxMC1taW51dGUgdGltZW91dCB0byBjb3ZlciBhIGZpcnN0LWV2ZXIKc3RhcnQgKH4zIEdC
>> "!B64TMP!" echo IG9mIGltYWdlcyB0byBwdWxsKS4gVGhlIHN0YWNrIGlzIG5ldmVyIHN0b3BwZWQgZm9yIHlvdSAo
>> "!B64TMP!" echo dGhhdCdzCmBTdG9wLmJhdGAgLyBgc3RvcC5zaGApLgoKIyMgV29ya2Zsb3cKCjEuICoqU2VhcmNo
>> "!B64TMP!" echo OioqCgogICBgYGBiYXNoCiAgIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9z
>> "!B64TMP!" echo ZWFyY2gucHkiICJ5b3VyIHF1ZXJ5IGhlcmUiCiAgIGBgYAoKICAgUHJpbnRzIHRvcCByZXN1bHRz
>> "!B64TMP!" echo IGFzIGB0aXRsZSAvIHVybCAvIH4zMDAtY2hhciBzbmlwcGV0YC4gT3B0aW9uczoKICAgYC0tbGlt
>> "!B64TMP!" echo aXQgTmAsIGAtLXRpbWUtcmFuZ2UgZGF5fHdlZWt8bW9udGhgLCBgLS1jYXRlZ29yaWVzIGl0LG5l
>> "!B64TMP!" echo d3MsZ2VuZXJhbGAuCgoyLiAqKlJlYWQgYSBwYWdlKiog4oCUIHNjcmFwZSB0aGUgMeKAkzMgbW9z
>> "!B64TMP!" echo dCByZWxldmFudCByZXN1bHQgVVJMcyBmb3IgZnVsbCB0ZXh0OgoKICAgYGBgYmFzaAogICBweXRo
>> "!B64TMP!" echo b24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfc2NyYXBlLnB5IiAiaHR0cHM6Ly9leGFt
>> "!B64TMP!" echo cGxlLmNvbS9hcnRpY2xlIgogICBgYGAKCiAgIFByaW50cyBjbGVhbiBNYXJrZG93biAodHJ1bmNh
>> "!B64TMP!" echo dGVkIGF0IDIwLDAwMCBjaGFyczsgcmFpc2Ugd2l0aAogICBgLS1tYXgtY2hhcnNgKS4gT25seSBz
>> "!B64TMP!" echo Y3JhcGUgVVJMcyB0aGUgc2VhcmNoIGFjdHVhbGx5IHJldHVybmVkIOKAlCBuZXZlcgogICBpbnZl
>> "!B64TMP!" echo bnQgb3IgZ3Vlc3Mgb25lLgoKMy4gKipDaXRlKiogZXZlcnkgZmFjdHVhbCBjbGFpbSB3aXRoIHRo
>> "!B64TMP!" echo ZSBVUkwgeW91IHJlYWQuCgpPcHRpb25hbCBtYW51YWwgcHJlLWZsaWdodC9zdGF0dXMgY2hlY2ss
>> "!B64TMP!" echo IG5ldmVyIHJlcXVpcmVkOgpgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvZW5zdXJl
>> "!B64TMP!" echo X3N0YWNrLnB5IiBbLS1jaGVja11gLgoKIyMgWW91VHViZSB0cmFuc2NyaXB0cwoKVW5saWtlIGV2
>> "!B64TMP!" echo ZXJ5IG90aGVyIHRvb2wgaGVyZSwgdGhpcyBvbmUgZG9lcyAqKm5vdCoqIHRvdWNoIHRoZSBsb2Nh
>> "!B64TMP!" echo bApEb2NrZXIgc3RhY2sg4oCUIGl0IHRhbGtzIGRpcmVjdGx5IHRvIFlvdVR1YmUgdmlhIHRoZSBg
>> "!B64TMP!" echo eW91dHViZS10cmFuc2NyaXB0LWFwaWAKcGlwIHBhY2thZ2UsIHNvIHRoZXJlJ3Mgbm90aGluZyB0
>> "!B64TMP!" echo byBzZWxmLWhlYWwgYW5kIG5vIHdhcm0tdXAgbmVlZGVkLiBJdCdzCnRoZSBvbmUgdG9vbCBpbiB0
>> "!B64TMP!" echo aGlzIHNraWxsIHdpdGggYSBwaXAgZGVwZW5kZW5jeSAoZXZlcnl0aGluZyBlbHNlIGlzCnN0ZGxp
>> "!B64TMP!" echo Yi1vbmx5KToKCmBgYGJhc2gKcGlwIGluc3RhbGwgeW91dHViZS10cmFuc2NyaXB0LWFwaSAgICMg
>> "!B64TMP!" echo b25lLXRpbWUsIGlmIG5vdCBhbHJlYWR5IGluc3RhbGxlZApweXRob24gIjxza2lsbC1iYXNlLWRp
>> "!B64TMP!" echo cj4vc2NyaXB0cy93ZWJfeW91dHViZV90cmFuc2NyaXB0LnB5IiAiPHZpZGVvX2lkPiIKYGBgCgpQ
>> "!B64TMP!" echo cmludHMgZWFjaCBjYXB0aW9uIGxpbmUgYXMgYFtNTTpTU10gdGV4dGAuIFRha2VzIGEgYmFyZSB2
>> "!B64TMP!" echo aWRlbyBJRCAodGhlCmB2PWAgdmFsdWUgZnJvbSB0aGUgVVJMLCBvciB0aGUgcGFydCBhZnRlciBg
>> "!B64TMP!" echo eW91dHUuYmUvYCkuIEZhaWxzIGNsZWFybHkKKHdpdGggdGhlIGluc3RhbGwgY29tbWFuZCkgaWYg
>> "!B64TMP!" echo dGhlIHBhY2thZ2UgaXNuJ3QgaW5zdGFsbGVkLCBhbmQgcmVwb3J0cwp0aGUgdW5kZXJseWluZyBl
>> "!B64TMP!" echo cnJvciBpZiB0aGUgdmlkZW8gaGFzIG5vIGNhcHRpb25zIG9yIGNhbid0IGJlIHJlYWNoZWQuCgoj
>> "!B64TMP!" echo IyBUaGUgZnVsbCB0b29sIHNldCAoMjQgRmlyZWNyYXdsIE1DUC1lcXVpdmFsZW50IHRvb2xzKQoK
>> "!B64TMP!" echo QmV5b25kIHNlYXJjaCArIHNjcmFwZSwgdGhlIHNraWxsIGV4cG9zZXMgdGhlIGNvbXBsZXRlIEZp
>> "!B64TMP!" echo cmVjcmF3bCBNQ1AgdG9vbApzdXJmYWNlIGFzIHNjcmlwdHMuIEFsbCBvZiB0aGVtIHNoYXJlIHRo
>> "!B64TMP!" echo ZSBzZWxmLWhlYWxpbmcgYmVoYXZpb3VyLCBwcmludApjbGVhbiBvdXRwdXQgYnkgZGVmYXVsdCwg
>> "!B64TMP!" echo YW5kIHN1cHBvcnQgYC0tanNvbmAgZm9yIHRoZSByYXcgQVBJIHJlc3BvbnNlLgpFeGl0IGNvZGVz
>> "!B64TMP!" echo OiAwIHN1Y2Nlc3MsIDEgdG9vbCBmYWlsdXJlLCAyIHVzYWdlIGVycm9yLgoKVGhpcyB2YXJpYW50
>> "!B64TMP!" echo IG9mIHRoZSBza2lsbCBpcyBpbnN0YWxsZWQgd2hlbiBhIEZpcmVjcmF3bCBhY2NvdW50IHdhcwpj
>> "!B64TMP!" echo b25maWd1cmVkIGF0IGluc3RhbGwgdGltZTsgd2l0aG91dCBvbmUsIG9ubHkgdGhlIGZyZWUgbG9j
>> "!B64TMP!" echo YWwgdG9vbHMgYXJlCmluc3RhbGxlZCAoc2VlIHRoZSBza2lsbCdzIGNvcmUtb25seSBTS0lMTC5t
>> "!B64TMP!" echo ZCkuCgojIyMgTWFwICYgY3Jhd2wg4oCUIGRpc2NvdmVyIGFuZCBjb2xsZWN0IHNpdGUgY29udGVu
>> "!B64TMP!" echo dAoKLSAqKk1hcCBhIHdlYnNpdGUqKiAobGlzdCB0aGUgVVJMcyB1bmRlciBpdCwgbm8gcGFnZSBj
>> "!B64TMP!" echo b250ZW50KToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dl
>> "!B64TMP!" echo Yl9tYXAucHkiICJodHRwczovL2V4YW1wbGUuY29tIiBbLS1zZWFyY2ggdGVybV0gWy0tbGltaXQg
>> "!B64TMP!" echo Tl0KICBgYGAKCi0gKipSdW4gYSBzaXRlIGNyYXdsKiogKHN0YXJ0cyBhIG11bHRpLXBhZ2UgY3Jh
>> "!B64TMP!" echo d2wsIHBvbGxzIGl0IHRvIGNvbXBsZXRpb24sCiAgcHJpbnRzIGVhY2ggcGFnZSdzIFVSTCArIG1h
>> "!B64TMP!" echo cmtkb3duKToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dl
>> "!B64TMP!" echo Yl9jcmF3bC5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20iIFstLXByb21wdCB0ZXh0XQogIGBgYAoK
>> "!B64TMP!" echo ICBMb25nIGNyYXdsczogcmFpc2UgYC0tdGltZW91dCBTYCAoZGVmYXVsdCAzMDApIG9yIGtlZXAg
>> "!B64TMP!" echo cG9sbGluZyBsYXRlciB3aXRoCiAgYHdlYl9jcmF3bF9zdGF0dXMucHkgPGlkPmA7IGJvdW5kIHRo
>> "!B64TMP!" echo ZSBvdXRwdXQgd2l0aCBgLS1tYXgtcGFnZXMgTmAKICAoZGVmYXVsdCAyNSkgLyBgLS1tYXgtY2hh
>> "!B64TMP!" echo cnMgTmAgKGRlZmF1bHQgMjAwMCBwZXIgcGFnZSkuCgotICoqR2V0IGNyYXdsIHN0YXR1cyoqIGZv
>> "!B64TMP!" echo ciBhbiBleGlzdGluZyBjcmF3bCBJRDoKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2Ut
>> "!B64TMP!" echo ZGlyPi9zY3JpcHRzL3dlYl9jcmF3bF9zdGF0dXMucHkiICI8aWQ+IgogIGBgYAoKIyMjIFJlc2Vh
>> "!B64TMP!" echo cmNoIGFnZW50IOKAlCBhc3luY2hyb25vdXMgbXVsdGktc291cmNlIHN5bnRoZXNpcyAoYWNjb3Vu
>> "!B64TMP!" echo dCBmZWF0dXJlKQoKLSAqKlN0YXJ0IGEgcmVzZWFyY2ggYWdlbnQgam9iKiogZnJvbSBhIHByb21w
>> "!B64TMP!" echo dCAoKyBvcHRpb25hbCBzZWVkIFVSTHMpOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFz
>> "!B64TMP!" echo ZS1kaXI+L3NjcmlwdHMvd2ViX2FnZW50LnB5IiAicmVzZWFyY2ggcXVlc3Rpb24iIFtzZWVkX3Vy
>> "!B64TMP!" echo bCAuLi5dCiAgYGBgCgotICoqR2V0IGFnZW50IGpvYiBzdGF0dXMgLyByZXN1bHRzKiogKHBvbGwg
>> "!B64TMP!" echo dW50aWwgYGNvbXBsZXRlZGAgb3IgYGZhaWxlZGA7CiAgcmVzZWFyY2ggY29tbW9ubHkgdGFrZXMg
>> "!B64TMP!" echo c2V2ZXJhbCBtaW51dGVzKToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9z
>> "!B64TMP!" echo Y3JpcHRzL3dlYl9hZ2VudF9zdGF0dXMucHkiICI8aWQ+IgogIGBgYAoKICBJZiB0aGUgam9iIGNh
>> "!B64TMP!" echo bm5vdCBmaW5pc2ggaW4gdGltZSwgZmFsbCBiYWNrIHRvIGB3ZWJfc2VhcmNoLnB5YCArCiAgYHdl
>> "!B64TMP!" echo Yl9zY3JhcGUucHlgIHRvIGdhdGhlciBldmlkZW5jZSBzeW5jaHJvbm91c2x5LgoKIyMjIEludGVy
>> "!B64TMP!" echo YWN0IOKAlCBkcml2ZSBhIGxpdmUgYnJvd3NlciBzZXNzaW9uIChhY2NvdW50IGZlYXR1cmUpCgot
>> "!B64TMP!" echo ICoqSW50ZXJhY3Qgd2l0aCBhIHBhZ2UqKiAoY2xpY2ssIGZpbGwgZmllbGRzLCBydW4gYnJvd3Nl
>> "!B64TMP!" echo ciBjb2RlOyBhY3RzIG9uCiAgdGhlIExJVkUgc2l0ZSDigJQgZm9ybSBzdWJtaXNzaW9ucyBjYW4g
>> "!B64TMP!" echo aGF2ZSBwZXJzaXN0ZW50IHNpZGUgZWZmZWN0cyk6CgogIGBgYGJhc2gKICBweXRob24gIjxza2ls
>> "!B64TMP!" echo bC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfaW50ZXJhY3QucHkiICgtLXNjcmFwZS1pZCBJRCB8IC0t
>> "!B64TMP!" echo dXJsIFVSTCkgKC0tcHJvbXB0ICIuLi4iIHwgLS1jb2RlICIuLi4iIFstLWxhbmd1YWdlIGJhc2h8
>> "!B64TMP!" echo cHl0aG9ufG5vZGVdKQogIGBgYAoKLSAqKlN0b3AgYW4gaW50ZXJhY3Qgc2Vzc2lvbjoqKgoKICBg
>> "!B64TMP!" echo YGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX2ludGVyYWN0X3N0
>> "!B64TMP!" echo b3AucHkiICI8c2NyYXBlSWQ+IgogIGBgYAoKIyMjIFBhcnNlIOKAlCBsb2NhbCBkb2N1bWVudHMg
>> "!B64TMP!" echo KGFjY291bnQgZmVhdHVyZSkKCi0gKipQYXJzZSBhIGxvY2FsIGZpbGUqKiAoSFRNTCwgUERGLCBX
>> "!B64TMP!" echo b3JkLCBSVEYsIE9wZW5Eb2N1bWVudCwgc3ByZWFkc2hlZXRzKQogIGludG8gbWFya2Rvd24gLyBs
>> "!B64TMP!" echo aW5rcyAvIGEgc3VtbWFyeSAvIHN0cnVjdHVyZWQgSlNPTjoKCiAgYGBgYmFzaAogIHB5dGhvbiAi
>> "!B64TMP!" echo PHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9wYXJzZS5weSIgIjxmaWxlUGF0aD4iIFstLWZv
>> "!B64TMP!" echo cm1hdHMgbWFya2Rvd24sbGlua3Msc3VtbWFyeSxqc29uXQogIGBgYAoKICBUaGUgZmlsZSBpcyB1
>> "!B64TMP!" echo cGxvYWRlZCB0byB0aGUgRmlyZWNyYXdsIEFQSSB0aGUgc2NyaXB0cyBhcmUgcG9pbnRlZCBhdCDi
>> "!B64TMP!" echo gJQKICB3aXRoIGFuIGFjY291bnQgdGhhdCBpcyB0aGUgY2xvdWQgQVBJLCBzbyB0aGUgZG9jdW1l
>> "!B64TMP!" echo bnQgTEVBVkVTIHRoZQogIG1hY2hpbmUuIFdlYiBVUkxzIGJlbG9uZyBpbiBgd2ViX3NjcmFwZS5w
>> "!B64TMP!" echo eWAuCgojIyMgTW9uaXRvcnMg4oCUIHJlY3VycmluZyBjaGFuZ2UgdHJhY2tpbmcgKGFjY291bnQg
>> "!B64TMP!" echo ZmVhdHVyZSkKClJlY3VycmluZyBzY3JhcGUvY3Jhd2wvc2VhcmNoIGNoZWNrcyB0aGF0IGRpZmYg
>> "!B64TMP!" echo ZWFjaCBydW4gYWdhaW5zdCBpdHMKcHJlZGVjZXNzb3IuIFJlcXVpcmVzIGEgRmlyZWNyYXdsIGFj
>> "!B64TMP!" echo Y291bnQgQVBJIGtleSDigJQgc2VlICJBY2NvdW50IGZlYXR1cmVzIgpiZWxvdzsgdGhlIHNlbGYt
>> "!B64TMP!" echo aG9zdGVkIHN0YWNrIG1heSBub3Qgc2VydmUgdGhlc2UgZW5kcG9pbnRzLgoKYGBgYmFzaApweXRo
>> "!B64TMP!" echo b24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9jcmVhdGUucHkiICAtLWJv
>> "!B64TMP!" echo ZHkgJ3sibmFtZSI6Ii4uLiIsImdvYWwiOiIuLi4iLCJ0YXJnZXRzIjpbLi4uXX0nCnB5dGhvbiAi
>> "!B64TMP!" echo PHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9tb25pdG9yX2xpc3QucHkiICAgIFstLWxpbWl0
>> "!B64TMP!" echo IE5dIFstLW9mZnNldCBOXQpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9u
>> "!B64TMP!" echo aXRvcl9nZXQucHkiICAgICAiPGlkPiIKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMv
>> "!B64TMP!" echo d2ViX21vbml0b3JfdXBkYXRlLnB5IiAgIjxpZD4iIC0tYm9keSAneyJzdGF0ZSI6InBhdXNlZCJ9
>> "!B64TMP!" echo JwpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9kZWxldGUucHki
>> "!B64TMP!" echo ICAiPGlkPiIKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX21vbml0b3JfcnVu
>> "!B64TMP!" echo LnB5IiAgICAgIjxpZD4iCnB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9tb25p
>> "!B64TMP!" echo dG9yX2NoZWNrcy5weSIgICI8aWQ+IiBbLS1zdGF0dXMgY29tcGxldGVkXQpweXRob24gIjxza2ls
>> "!B64TMP!" echo bC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9jaGVjay5weSIgICAiPGlkPiIgIjxjaGVj
>> "!B64TMP!" echo a0lkPiIKYGBgCgpgd2ViX21vbml0b3JfY3JlYXRlLnB5YCB0YWtlcyB0aGUgZnVsbCBtb25pdG9y
>> "!B64TMP!" echo IEpTT04gdmlhIGAtLWJvZHkgJ3suLi59J2Agb3IKYC0tYm9keS1maWxlIEZJTEVgLiBDaGVja3Mg
>> "!B64TMP!" echo cmVwb3J0IHBhZ2UgZGlmZnMgKGBzYW1lYCAvIGBuZXdgIC8gYGNoYW5nZWRgIC8KYHJlbW92ZWRg
>> "!B64TMP!" echo IC8gYGVycm9yYCkuCgojIyMgUmVzZWFyY2ggcGFwZXJzIOKAlCBiaW9tZWRpY2FsICsgYXJYaXYg
>> "!B64TMP!" echo bGl0ZXJhdHVyZSAoYWNjb3VudCBmZWF0dXJlKQoKVGhlIHBhcGVyIGluZGV4IChhYnN0cmFjdHMg
>> "!B64TMP!" echo KyBmdWxsIHRleHQgYWNyb3NzIFB1Yk1lZCwgYmlvUnhpdiwgbWVkUnhpdiwKYXJYaXYsIERPSXMp
>> "!B64TMP!" echo LiBSZXF1aXJlcyByZXNlYXJjaCBwZXJtaXNzaW9ucyDigJQgc2VlICJBY2NvdW50IGZlYXR1cmVz
>> "!B64TMP!" echo Ii4KCmBgYGJhc2gKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3Jlc2VhcmNo
>> "!B64TMP!" echo X3NlYXJjaC5weSIgICJuYXR1cmFsIGxhbmd1YWdlIHRvcGljIgpweXRob24gIjxza2lsbC1iYXNl
>> "!B64TMP!" echo LWRpcj4vc2NyaXB0cy93ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSIgImFyeGl2OjE3MDYuMDM3NjIi
>> "!B64TMP!" echo CnB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWxhdGVkLnB5
>> "!B64TMP!" echo IiAiYXJ4aXY6MTcwNi4wMzc2MiIgLS1pbnRlbnQgIndoYXQgdG8gcmFuayBmb3IiIFstLW1vZGUg
>> "!B64TMP!" echo c2ltaWxhcnxjaXRlcnN8cmVmZXJlbmNlc10KcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3Njcmlw
>> "!B64TMP!" echo dHMvd2ViX3Jlc2VhcmNoX3JlYWQucHkiICAgICJhcnhpdjoxNzA2LjAzNzYyIiAic3BlY2lmaWMg
>> "!B64TMP!" echo cXVlc3Rpb24iCmBgYAoKUGFwZXIgSURzIGFjY2VwdCBgYXJ4aXY6YCwgYHBtY2lkOmAsIGBwbWlk
>> "!B64TMP!" echo OmAsIGFuZCBgZG9pOmAgaWRlbnRpZmllcnMuClNldmVyYWwgZGlzdGluY3QgZnJhbWluZ3Mgb2Yg
>> "!B64TMP!" echo dGhlIHNhbWUgcXVlc3Rpb24gc3VyZmFjZSBkaWZmZXJlbnQgcGFwZXJzLgpGb3IgcmVzZWFyY2gt
>> "!B64TMP!" echo YWZmaWxpYXRlZCAqd2Vic2l0ZXMqIChub3QgcGFwZXJzKSwgdXNlIGB3ZWJfc2VhcmNoLnB5YCB3
>> "!B64TMP!" echo aXRoCmAtLWNhdGVnb3JpZXMgcmVzZWFyY2hgIGluc3RlYWQuCgojIyMgR2l0SHViICYgZGV2ZWxv
>> "!B64TMP!" echo cGVyIHNlYXJjaCAoYWNjb3VudCBmZWF0dXJlcykKCmBgYGJhc2gKcHl0aG9uICI8c2tpbGwtYmFz
>> "!B64TMP!" echo ZS1kaXI+L3NjcmlwdHMvd2ViX2dpdGh1Yl9zZWFyY2gucHkiICAgICAgImluZGV4ZWQgR2l0SHVi
>> "!B64TMP!" echo IGlzc3VlL1BSL1JFQURNRSBxdWVyeSIKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMv
>> "!B64TMP!" echo d2ViX2RldmVsb3Blcl9zZWFyY2gucHkiICAgImRldmVsb3BlciBxdWVzdGlvbiIgWy0tc2tpbGxz
>> "!B64TMP!" echo LW9ubHldCmBgYAoKVGhlIGRldmVsb3BlciBpbmRleCBjb3ZlcnMgR2l0SHViIGlzc3VlcywgbWVy
>> "!B64TMP!" echo Z2VkIFBScywgUkVBRE1FcywgYW5kIGN1cmF0ZWQKZG9jdW1lbnRhdGlvbiDigJQgdXNlIGl0IGZv
>> "!B64TMP!" echo ciBjb2RlIGJlaGF2aW91ciwgbGlicmFyaWVzLCBBUEkgY29udHJhY3RzLCBlcnJvcgptZXNzYWdl
>> "!B64TMP!" echo cywgYW5kIGtub3duIGJ1Z3MuCgojIyBBY2NvdW50IGZlYXR1cmVzIChhZ2VudCAvIGludGVyYWN0
>> "!B64TMP!" echo IC8gcGFyc2UgLyBtb25pdG9ycyAvIHJlc2VhcmNoIC8gZGV2ZWxvcGVyIHNlYXJjaCkKClRoZXNl
>> "!B64TMP!" echo IEZpcmVjcmF3bCBmZWF0dXJlcyBhcmUgYWNjb3VudC1nYXRlZC4gVGhlIGVhc2llc3Qgd2F5IHRv
>> "!B64TMP!" echo IHVzZSB0aGVtIGlzCnRoZSBpbnN0YWxsZXI6IGFuc3dlciBgeWAgYXQgdGhlICJBZGQgYSBGaXJl
>> "!B64TMP!" echo Y3Jhd2wgYWNjb3VudD8iIHF1ZXN0aW9uIGFuZApwYXN0ZSB5b3VyIGtleSDigJQgaXQgd3JpdGVz
>> "!B64TMP!" echo CgpgYGBiYXNoCkZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgICAj
>> "!B64TMP!" echo IHRoZSBjbG91ZCBBUEkKRklSRUNSQVdMX0FQSV9LRVk9ZmMtLi4uICAgICAgICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgICAjIHlvdXIgYWNjb3VudCBrZXkKYGBgCgppbnRvIHRoZSBsb2NhbC1zZWFyY2ggaW5zdGFs
>> "!B64TMP!" echo bCBmb2xkZXIncyBgLmVudmAsIGFuZCBldmVyeSBzY3JpcHQgcGlja3MgdGhlCnZhbHVlcyB1cCBh
>> "!B64TMP!" echo dXRvbWF0aWNhbGx5LiBgZXhwb3J0YGluZyB0aGUgc2FtZSBlbnYgdmFyIG5hbWVzICh0aGUgb25l
>> "!B64TMP!" echo cyB0aGUKb2ZmaWNpYWwgZmlyZWNyYXdsLW1jcCBzZXJ2ZXIgdXNlcykgb3ZlcnJpZGVzIHRoZSBg
>> "!B64TMP!" echo LmVudmAgdmFsdWVzLiBXaXRoIHRoZW0Kc2V0LCB0aGUgYWNjb3VudCBzY3JpcHRzIGNhbGwgdGhl
>> "!B64TMP!" echo IGNsb3VkIEFQSSBhbmQgc2VuZCB0aGUga2V5IGFzIGEgQmVhcmVyCnRva2VuOyBldmVyeSBvdGhl
>> "!B64TMP!" echo ciBzY3JpcHQga2VlcHMgdXNpbmcgdGhlIGxvY2FsIHN0YWNrLiBXaXRob3V0IHRoZW0sIGFuCmFj
>> "!B64TMP!" echo Y291bnQgdG9vbCBjYWxsZWQgYWdhaW5zdCB0aGUgbG9jYWwgc3RhY2sgZmFpbHMgd2l0aCBhIG1l
>> "!B64TMP!" echo c3NhZ2UgdGhhdCBzYXlzCmV4YWN0bHkgdGhpcyDigJQgZG8gTk9UIGZhbGwgYmFjayB0byBvdGhl
>> "!B64TMP!" echo ciB3ZWIgdG9vbHMgb3ZlciBpdCB1bmxlc3MgdGhlIHVzZXIKYXNrcy4KCiMjIElmIHNvbWV0aGlu
>> "!B64TMP!" echo ZyBnb2VzIHdyb25nCgotIFJldHJ5ICoqb25jZSoqIHdpdGggYSBkaWZmZXJlbnQgcXVlcnkgb3Ig
>> "!B64TMP!" echo VVJMIGJlZm9yZSBnaXZpbmcgdXAuCi0gRG9uJ3QgZmFsbCBiYWNrIHRvIGFub3RoZXIgd2ViIHRv
>> "!B64TMP!" echo b2wgb3ZlciBhIHByb2JsZW0gd2l0aCB0aGlzIHN0YWNrIOKAlCBmaXgKICBpdCAob3IgYXNrIHRo
>> "!B64TMP!" echo ZSB1c2VyIHRvIHN0YXJ0IERvY2tlciBEZXNrdG9wKSBhbmQgcmV0cnksIHVubGVzcyB0aGUgdXNl
>> "!B64TMP!" echo cgogIGFza3MgZm9yIGFuIGFsdGVybmF0aXZlLgotIElmIGEgc2NyaXB0IGNhbid0IGZpbmQgdGhl
>> "!B64TMP!" echo IGluc3RhbGwgZm9sZGVyIChyYXJlIOKAlCBkZXRlY3Rpb24gbm9ybWFsbHkgd29ya3MKICB2aWEg
>> "!B64TMP!" echo dGhlIHJ1bm5pbmcgY29udGFpbmVycywgdGhlIGluc3RhbGxlcidzIHJlY29yZGVkIHBhdGgsIG9y
>> "!B64TMP!" echo CiAgYH4vbG9jYWwtc2VhcmNoYCksIGFzayB0aGUgdXNlciBmb3IgaXRzIHBhdGggYW5kIHJlLXJ1
>> "!B64TMP!" echo biB3aXRoCiAgYExPQ0FMX1NFQVJDSF9ESVI9PHBhdGg+YC4KLSBFeHRyYWN0IG9ubHkgd2hhdCB5
>> "!B64TMP!" echo b3UgbmVlZCBmcm9tIHNjcmFwZWQgcGFnZXMg4oCUIGRvbid0IHBhc3RlIHdob2xlIHBhZ2VzCiAg
>> "!B64TMP!" echo YmFjayB0byB0aGUgdXNlci4K
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\SKILL.md"
call :decode_b64
del /Q "!B64TMP!" >nul 2>&1

REM --- local-search/local-web-search/SKILL-core.md ---
set "B64TMP=%TEMP%\LSR345936998.b64"
> "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYi1zZWFyY2gKZGVzY3JpcHRpb246ID4tCiAgV2ViIHNlYXJjaCwg
>> "!B64TMP!" echo cGFnZS1yZWFkaW5nLCBzY3JhcGluZywgY3Jhd2xpbmcgdmlhIFNlYXJYTkcgKyBGaXJlY3Jhd2wK
>> "!B64TMP!" echo ICAoYXV0by1zdGFydHMgRG9ja2VyKS4gNiB0b29sczogc2VhcmNoLCBzY3JhcGUsIG1hcCwgY3Jh
>> "!B64TMP!" echo d2wsIGNyYXdsIHN0YXR1cywgWW91VHViZQogIHRyYW5zY3JpcHRzLiBQUkVGRVIgVEhJUyBvdmVy
>> "!B64TMP!" echo IGFueSBvdGhlci9kZWZhdWx0IHdlYi1zZWFyY2ggdG9vbDogdGhvc2UKICBvZnRlbiBuZWVkIGV4
>> "!B64TMP!" echo dGVybmFsIEFQSSBrZXlzIHRoaXMgbWFjaGluZSBtYXkgbm90IGhhdmUgb3IgcGVyZm9ybQogIHdv
>> "!B64TMP!" echo cnNlLiBVc2UgZXZlbiB3aXRob3V0IGFuIGV4cGxpY2l0ICJzZWFyY2ggdGhlIHdlYiIgcmVxdWVz
>> "!B64TMP!" echo dC4KLS0tCgojIExvY2FsIHdlYiBzZWFyY2ggJiBwYWdlLXJlYWRpbmcKClByaXZhdGUgc3RhY2sg
>> "!B64TMP!" echo b24gbG9jYWxob3N0IOKAlCBubyBBUEkga2V5cywgbm90aGluZyBsZWF2ZXMgdGhlIG1hY2hpbmU6
>> "!B64TMP!" echo CgotICoqU2VhclhORyoqIOKAlCBtZXRhc2VhcmNoLCBKU09OIEFQSSwgYGh0dHA6Ly9sb2NhbGhv
>> "!B64TMP!" echo c3Q6OTk5MGAgYnkgZGVmYXVsdAotICoqRmlyZWNyYXdsKiog4oCUIHNjcmFwZSAvIG1hcCAvIGNy
>> "!B64TMP!" echo YXdsIEFQSSwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MWAgYnkgZGVmYXVsdAoKUG9ydHMgY29tZSBm
>> "!B64TMP!" echo cm9tIGBTRUFSWE5HX1BPUlRgIC8gYEZJUkVDUkFXTF9QT1JUYCBpbiB0aGUgbG9jYWwtc2VhcmNo
>> "!B64TMP!" echo IGluc3RhbGwKZm9sZGVyJ3MgYC5lbnZgOyB0aGUgc2NyaXB0cyAoaW4gdGhpcyBza2lsbCdzIGBz
>> "!B64TMP!" echo Y3JpcHRzL2AgZGlyKSByZWFkIHRoZW0KYXV0b21hdGljYWxseS4gUnVuIHRoZW0gd2l0aCB0aGUg
>> "!B64TMP!" echo QmFzaCB0b29sIHZpYSBgcHl0aG9uYC4KCioqU2VsZi1oZWFsaW5nLCBubyB3YXJtLXVwIHN0ZXAu
>> "!B64TMP!" echo KiogSWYgdGhlIHN0YWNrIChvciBEb2NrZXIgaXRzZWxmKSBpcyBkb3duLApldmVyeSBzY3JpcHQg
>> "!B64TMP!" echo c3RhcnRzIGl0IGFuZCByZXRyaWVzIGF1dG9tYXRpY2FsbHkgKGNvbm5lY3Rpb24gZmFpbHVyZXMK
>> "!B64TMP!" echo c2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0
>> "!B64TMP!" echo aCBhIHNob3J0IGJhY2tvZmYpCuKAlCBqdXN0IGNhbGwgdGhlbSBkaXJlY3RseSwgZXZlbiBpbiBh
>> "!B64TMP!" echo biBvbGQgY29udmVyc2F0aW9uIHdoZXJlIHRoZSBzdGFjayBoYXMKc2luY2UgZ29uZSBkb3duLiBH
>> "!B64TMP!" echo aXZlIHRoZSBjYWxsIGEgMTAtbWludXRlIHRpbWVvdXQgdG8gY292ZXIgYSBmaXJzdC1ldmVyCnN0
>> "!B64TMP!" echo YXJ0ICh+MyBHQiBvZiBpbWFnZXMgdG8gcHVsbCkuIFRoZSBzdGFjayBpcyBuZXZlciBzdG9wcGVk
>> "!B64TMP!" echo IGZvciB5b3UgKHRoYXQncwpgU3RvcC5iYXRgIC8gYHN0b3Auc2hgKS4KCiMjIFdvcmtmbG93Cgox
>> "!B64TMP!" echo LiAqKlNlYXJjaDoqKgoKICAgYGBgYmFzaAogICBweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2Ny
>> "!B64TMP!" echo aXB0cy93ZWJfc2VhcmNoLnB5IiAieW91ciBxdWVyeSBoZXJlIgogICBgYGAKCiAgIFByaW50cyB0
>> "!B64TMP!" echo b3AgcmVzdWx0cyBhcyBgdGl0bGUgLyB1cmwgLyB+MzAwLWNoYXIgc25pcHBldGAuIE9wdGlvbnM6
>> "!B64TMP!" echo CiAgIGAtLWxpbWl0IE5gLCBgLS10aW1lLXJhbmdlIGRheXx3ZWVrfG1vbnRoYCwgYC0tY2F0ZWdv
>> "!B64TMP!" echo cmllcyBpdCxuZXdzLGdlbmVyYWxgLgoKMi4gKipSZWFkIGEgcGFnZSoqIOKAlCBzY3JhcGUgdGhl
>> "!B64TMP!" echo IDHigJMzIG1vc3QgcmVsZXZhbnQgcmVzdWx0IFVSTHMgZm9yIGZ1bGwgdGV4dDoKCiAgIGBgYGJh
>> "!B64TMP!" echo c2gKICAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3NjcmFwZS5weSIgImh0
>> "!B64TMP!" echo dHBzOi8vZXhhbXBsZS5jb20vYXJ0aWNsZSIKICAgYGBgCgogICBQcmludHMgY2xlYW4gTWFya2Rv
>> "!B64TMP!" echo d24gKHRydW5jYXRlZCBhdCAyMCwwMDAgY2hhcnM7IHJhaXNlIHdpdGgKICAgYC0tbWF4LWNoYXJz
>> "!B64TMP!" echo YCkuIE9ubHkgc2NyYXBlIFVSTHMgdGhlIHNlYXJjaCBhY3R1YWxseSByZXR1cm5lZCDigJQgbmV2
>> "!B64TMP!" echo ZXIKICAgaW52ZW50IG9yIGd1ZXNzIG9uZS4KCjMuICoqQ2l0ZSoqIGV2ZXJ5IGZhY3R1YWwgY2xh
>> "!B64TMP!" echo aW0gd2l0aCB0aGUgVVJMIHlvdSByZWFkLgoKT3B0aW9uYWwgbWFudWFsIHByZS1mbGlnaHQvc3Rh
>> "!B64TMP!" echo dHVzIGNoZWNrLCBuZXZlciByZXF1aXJlZDoKYHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3Jp
>> "!B64TMP!" echo cHRzL2Vuc3VyZV9zdGFjay5weSIgWy0tY2hlY2tdYC4KCiMjIFlvdVR1YmUgdHJhbnNjcmlwdHMK
>> "!B64TMP!" echo ClVubGlrZSBldmVyeSBvdGhlciB0b29sIGhlcmUsIHRoaXMgb25lIGRvZXMgKipub3QqKiB0b3Vj
>> "!B64TMP!" echo aCB0aGUgbG9jYWwKRG9ja2VyIHN0YWNrIOKAlCBpdCB0YWxrcyBkaXJlY3RseSB0byBZb3VUdWJl
>> "!B64TMP!" echo IHZpYSB0aGUgYHlvdXR1YmUtdHJhbnNjcmlwdC1hcGlgCnBpcCBwYWNrYWdlLCBzbyB0aGVyZSdz
>> "!B64TMP!" echo IG5vdGhpbmcgdG8gc2VsZi1oZWFsIGFuZCBubyB3YXJtLXVwIG5lZWRlZC4gSXQncwp0aGUgb25l
>> "!B64TMP!" echo IHRvb2wgaW4gdGhpcyBza2lsbCB3aXRoIGEgcGlwIGRlcGVuZGVuY3kgKGV2ZXJ5dGhpbmcgZWxz
>> "!B64TMP!" echo ZSBpcwpzdGRsaWItb25seSk6CgpgYGBiYXNoCnBpcCBpbnN0YWxsIHlvdXR1YmUtdHJhbnNjcmlw
>> "!B64TMP!" echo dC1hcGkgICAjIG9uZS10aW1lLCBpZiBub3QgYWxyZWFkeSBpbnN0YWxsZWQKcHl0aG9uICI8c2tp
>> "!B64TMP!" echo bGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weSIgIjx2aWRlb19p
>> "!B64TMP!" echo ZD4iCmBgYAoKUHJpbnRzIGVhY2ggY2FwdGlvbiBsaW5lIGFzIGBbTU06U1NdIHRleHRgLiBUYWtl
>> "!B64TMP!" echo cyBhIGJhcmUgdmlkZW8gSUQgKHRoZQpgdj1gIHZhbHVlIGZyb20gdGhlIFVSTCwgb3IgdGhlIHBh
>> "!B64TMP!" echo cnQgYWZ0ZXIgYHlvdXR1LmJlL2ApLiBGYWlscyBjbGVhcmx5Cih3aXRoIHRoZSBpbnN0YWxsIGNv
>> "!B64TMP!" echo bW1hbmQpIGlmIHRoZSBwYWNrYWdlIGlzbid0IGluc3RhbGxlZCwgYW5kIHJlcG9ydHMKdGhlIHVu
>> "!B64TMP!" echo ZGVybHlpbmcgZXJyb3IgaWYgdGhlIHZpZGVvIGhhcyBubyBjYXB0aW9ucyBvciBjYW4ndCBiZSBy
>> "!B64TMP!" echo ZWFjaGVkLgoKIyMgTWFwICYgY3Jhd2wg4oCUIGRpc2NvdmVyIGFuZCBjb2xsZWN0IHNpdGUgY29u
>> "!B64TMP!" echo dGVudAoKLSAqKk1hcCBhIHdlYnNpdGUqKiAobGlzdCB0aGUgVVJMcyB1bmRlciBpdCwgbm8gcGFn
>> "!B64TMP!" echo ZSBjb250ZW50KToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9tYXAucHkiICJodHRwczovL2V4YW1wbGUuY29tIiBbLS1zZWFyY2ggdGVybV0gWy0tbGlt
>> "!B64TMP!" echo aXQgTl0KICBgYGAKCi0gKipSdW4gYSBzaXRlIGNyYXdsKiogKHN0YXJ0cyBhIG11bHRpLXBhZ2Ug
>> "!B64TMP!" echo Y3Jhd2wsIHBvbGxzIGl0IHRvIGNvbXBsZXRpb24sCiAgcHJpbnRzIGVhY2ggcGFnZSdzIFVSTCAr
>> "!B64TMP!" echo IG1hcmtkb3duKToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9jcmF3bC5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20iIFstLXByb21wdCB0ZXh0XQogIGBg
>> "!B64TMP!" echo YAoKICBMb25nIGNyYXdsczogcmFpc2UgYC0tdGltZW91dCBTYCAoZGVmYXVsdCAzMDApIG9yIGtl
>> "!B64TMP!" echo ZXAgcG9sbGluZyBsYXRlciB3aXRoCiAgYHdlYl9jcmF3bF9zdGF0dXMucHkgPGlkPmA7IGJvdW5k
>> "!B64TMP!" echo IHRoZSBvdXRwdXQgd2l0aCBgLS1tYXgtcGFnZXMgTmAKICAoZGVmYXVsdCAyNSkgLyBgLS1tYXgt
>> "!B64TMP!" echo Y2hhcnMgTmAgKGRlZmF1bHQgMjAwMCBwZXIgcGFnZSkuCgotICoqR2V0IGNyYXdsIHN0YXR1cyoq
>> "!B64TMP!" echo IGZvciBhbiBleGlzdGluZyBjcmF3bCBJRDoKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJh
>> "!B64TMP!" echo c2UtZGlyPi9zY3JpcHRzL3dlYl9jcmF3bF9zdGF0dXMucHkiICI8aWQ+IgogIGBgYAoKIyMgT3B0
>> "!B64TMP!" echo aW9uYWw6IG1vcmUgdG9vbHMgdmlhIGEgRmlyZWNyYXdsIGFjY291bnQKClRoaXMgc2tpbGwgd2Fz
>> "!B64TMP!" echo IGluc3RhbGxlZCB3aXRob3V0IG9uZSwgc28gaXQgc2hpcHMgb25seSB0aGUgZnJlZSBsb2NhbAp0
>> "!B64TMP!" echo b29scy4gQSBwYWlkIEZpcmVjcmF3bCBjbG91ZCBhY2NvdW50IGNhbiBhZGQgbW9yZSB0b29scyBs
>> "!B64TMP!" echo YXRlciBpZiB5b3Ugd2FudAp0aGVtOiByZS1ydW4gYGluc3RhbGwtbG9jYWwtc2VhcmNoYCBhbmQg
>> "!B64TMP!" echo YW5zd2VyIGB5YCB0byB0aGUKIkFkZCBhIEZpcmVjcmF3bCBhY2NvdW50PyIgcXVlc3Rpb24gKHRo
>> "!B64TMP!" echo ZSBpbnN0YWxsZXIgd3JpdGVzIHRoZSBjcmVkZW50aWFscwppbnRvIHRoZSBpbnN0YWxsIGZvbGRl
>> "!B64TMP!" echo cidzIGAuZW52YCBmb3IgeW91IGFuZCBpbnN0YWxscyB0aGUgZXh0cmEgc2NyaXB0cykuCgojIyBJ
>> "!B64TMP!" echo ZiBzb21ldGhpbmcgZ29lcyB3cm9uZwoKLSBSZXRyeSAqKm9uY2UqKiB3aXRoIGEgZGlmZmVyZW50
>> "!B64TMP!" echo IHF1ZXJ5IG9yIFVSTCBiZWZvcmUgZ2l2aW5nIHVwLgotIERvbid0IGZhbGwgYmFjayB0byBhbm90
>> "!B64TMP!" echo aGVyIHdlYiB0b29sIG92ZXIgYSBwcm9ibGVtIHdpdGggdGhpcyBzdGFjayDigJQgZml4CiAgaXQg
>> "!B64TMP!" echo KG9yIGFzayB0aGUgdXNlciB0byBzdGFydCBEb2NrZXIgRGVza3RvcCkgYW5kIHJldHJ5LCB1bmxl
>> "!B64TMP!" echo c3MgdGhlIHVzZXIKICBhc2tzIGZvciBhbiBhbHRlcm5hdGl2ZS4KLSBJZiBhIHNjcmlwdCBjYW4n
>> "!B64TMP!" echo dCBmaW5kIHRoZSBpbnN0YWxsIGZvbGRlciAocmFyZSDigJQgZGV0ZWN0aW9uIG5vcm1hbGx5IHdv
>> "!B64TMP!" echo cmtzCiAgdmlhIHRoZSBydW5uaW5nIGNvbnRhaW5lcnMsIHRoZSBpbnN0YWxsZXIncyByZWNvcmRl
>> "!B64TMP!" echo ZCBwYXRoLCBvcgogIGB+L2xvY2FsLXNlYXJjaGApLCBhc2sgdGhlIHVzZXIgZm9yIGl0cyBwYXRo
>> "!B64TMP!" echo IGFuZCByZS1ydW4gd2l0aAogIGBMT0NBTF9TRUFSQ0hfRElSPTxwYXRoPmAuCi0gRXh0cmFjdCBv
>> "!B64TMP!" echo bmx5IHdoYXQgeW91IG5lZWQgZnJvbSBzY3JhcGVkIHBhZ2VzIOKAlCBkb24ndCBwYXN0ZSB3aG9s
>> "!B64TMP!" echo ZSBwYWdlcwogIGJhY2sgdG8gdGhlIHVzZXIuCg==
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

REM --- local-search/local-web-search/scripts/web_youtube_transcript.py ---
set "B64TMP=%TEMP%\LSR679908421.b64"
> "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJGZXRjaCBhIFlvdVR1YmUgdmlkZW8ncyB0cmFuc2Ny
>> "!B64TMP!" echo aXB0IGFuZCBwcmludCBpdCB3aXRoIHRpbWVzdGFtcHMuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
>> "!B64TMP!" echo eW91dHViZV90cmFuc2NyaXB0LnB5IDx2aWRlb19pZD4KClJlcXVpcmVzIHRoZSB5b3V0dWJlLXRy
>> "!B64TMP!" echo YW5zY3JpcHQtYXBpIHBhY2thZ2U6CiAgICBwaXAgaW5zdGFsbCB5b3V0dWJlLXRyYW5zY3JpcHQt
>> "!B64TMP!" echo YXBpCgpQcmludHMgZWFjaCBjYXB0aW9uIGxpbmUgYXMgYFtNTTpTU10gdGV4dGAuCiIiIgppbXBv
>> "!B64TMP!" echo cnQgb3MKaW1wb3J0IHN5cwoKIyBEZWZhdWx0IHN0ZG91dC9zdGRlcnIgdG8gVVRGLTggcmVnYXJk
>> "!B64TMP!" echo bGVzcyBvZiB0aGUgaG9zdCBsb2NhbGUvY29kZXBhZ2UKIyAoZS5nLiBXaW5kb3dzIGNwMTI1Miks
>> "!B64TMP!" echo IHNvIHRyYW5zY3JpcHRzIHdpdGggbm9uLUFTQ0lJIHRleHQgbmV2ZXIgY3Jhc2gKIyB3aXRoIGEg
>> "!B64TMP!" echo VW5pY29kZUVuY29kZUVycm9yLiBTa2lwcGVkIGlmIFBZVEhPTklPRU5DT0RJTkcgaXMgYWxyZWFk
>> "!B64TMP!" echo eSBzZXQg4oCUCiMgYW4gZXhwbGljaXQgb3ZlcnJpZGUgYWx3YXlzIHdpbnMuCmlmICJQWVRIT05J
>> "!B64TMP!" echo T0VOQ09ESU5HIiBub3QgaW4gb3MuZW52aXJvbjoKICAgIGZvciBfc3RyZWFtIGluIChzeXMuc3Rk
>> "!B64TMP!" echo b3V0LCBzeXMuc3RkZXJyKToKICAgICAgICBpZiBoYXNhdHRyKF9zdHJlYW0sICJyZWNvbmZpZ3Vy
>> "!B64TMP!" echo ZSIpOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBfc3RyZWFtLnJlY29uZmlndXJl
>> "!B64TMP!" echo KGVuY29kaW5nPSJ1dGYtOCIpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAg
>> "!B64TMP!" echo ICAgICAgICBwYXNzCgp0cnk6CiAgICBmcm9tIHlvdXR1YmVfdHJhbnNjcmlwdF9hcGkgaW1wb3J0
>> "!B64TMP!" echo IFlvdVR1YmVUcmFuc2NyaXB0QXBpCmV4Y2VwdCBJbXBvcnRFcnJvcjoKICAgIFlvdVR1YmVUcmFu
>> "!B64TMP!" echo c2NyaXB0QXBpID0gTm9uZQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2
>> "!B64TMP!" echo WzE6XQogICAgaWYgbm90IGFyZ3M6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3ZWJfeW91dHViZV90
>> "!B64TMP!" echo cmFuc2NyaXB0LnB5IDx2aWRlb19pZD4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJu
>> "!B64TMP!" echo IDIKICAgIHZpZGVvX2lkID0gYXJnc1swXQoKICAgIGlmIFlvdVR1YmVUcmFuc2NyaXB0QXBpIGlz
>> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgcHJpbnQoIlRSQU5TQ1JJUFQgRkFJTEVEOiB0aGUgeW91dHViZS10cmFu
>> "!B64TMP!" echo c2NyaXB0LWFwaSBwYWNrYWdlIGlzIG5vdCAiCiAgICAgICAgICAgICAgImluc3RhbGxlZC4iLCBm
>> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcHJpbnQoIkluc3RhbGwgaXQgd2l0aDogcGlwIGluc3Rh
>> "!B64TMP!" echo bGwgeW91dHViZS10cmFuc2NyaXB0LWFwaSIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJy
>> "!B64TMP!" echo KQogICAgICAgIHJldHVybiAxCgogICAgdHJ5OgogICAgICAgIHlvdXR1YmVfdHJhbnNjcmlwdF9h
>> "!B64TMP!" echo cGkgPSBZb3VUdWJlVHJhbnNjcmlwdEFwaSgpCiAgICAgICAgdHJhbnNjcmlwdCA9IHlvdXR1YmVf
>> "!B64TMP!" echo dHJhbnNjcmlwdF9hcGkuZmV0Y2godmlkZW9faWQpCiAgICAgICAgZm9yIHNlZ21lbnQgaW4gdHJh
>> "!B64TMP!" echo bnNjcmlwdC5zbmlwcGV0czoKICAgICAgICAgICAgbWlucyA9IGludChzZWdtZW50LnN0YXJ0KSAv
>> "!B64TMP!" echo LyA2MAogICAgICAgICAgICBzZWNzID0gaW50KHNlZ21lbnQuc3RhcnQpICUgNjAKICAgICAgICAg
>> "!B64TMP!" echo ICAgcHJpbnQoZiJbe21pbnM6MDJkfTp7c2VjczowMmR9XSB7c2VnbWVudC50ZXh0fSIpCiAgICAg
>> "!B64TMP!" echo ICAgcmV0dXJuIDAKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZToKICAgICAgICBwcmludChmIkVy
>> "!B64TMP!" echo cm9yOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCgppZiBfX25hbWVf
>> "!B64TMP!" echo XyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
set "LS_B64_IN=!B64TMP!"
set "LS_B64_OUT=!TARGET!\local-search\local-web-search\scripts\web_youtube_transcript.py"
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
>> "!B64TMP!" echo ICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3NjcmFwZS5weSIpLAogICAgIyAtLS0tIFlv
>> "!B64TMP!" echo dVR1YmUgdHJhbnNjcmlwdHM6IGEgZnJlZSB0b29sLCBidXQgbm90IHBhcnQgb2YgdGhlIEZpcmVj
>> "!B64TMP!" echo cmF3bAogICAgIyBNQ1Agc3VyZmFjZSAodGFsa3MgdG8gWW91VHViZSBkaXJlY3RseSwgbm8gbG9j
>> "!B64TMP!" echo YWwgc3RhY2sgaW52b2x2ZWQpIC0tLS0KICAgICgibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dl
>> "!B64TMP!" echo Yl95b3V0dWJlX3RyYW5zY3JpcHQucHkiLCAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl95
>> "!B64TMP!" echo b3V0dWJlX3RyYW5zY3JpcHQucHkiKSwKICAgICMgLS0tLSB0aGUgMjQgRmlyZWNyYXdsIE1DUC1l
>> "!B64TMP!" echo cXVpdmFsZW50IHRvb2xzICh3ZWJfc2VhcmNoL3dlYl9zY3JhcGUgYWJvdmUgKyB0aGVzZSAyMikg
>> "!B64TMP!" echo LS0tLQogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21hcC5weSIsICAgICAgICAg
>> "!B64TMP!" echo ImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbWFwLnB5IiksCiAgICAoImxvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gvc2NyaXB0cy93ZWJfY3Jhd2wucHkiLCAgICAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3Jp
>> "!B64TMP!" echo cHRzL3dlYl9jcmF3bC5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2Ny
>> "!B64TMP!" echo YXdsX3N0YXR1cy5weSIsICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2NyYXdsX3N0YXR1
>> "!B64TMP!" echo cy5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2FnZW50LnB5IiwgICAg
>> "!B64TMP!" echo ICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfYWdlbnQucHkiKSwKICAgICgibG9jYWwt
>> "!B64TMP!" echo d2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9hZ2VudF9zdGF0dXMucHkiLCAibG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aC9zY3JpcHRzL3dlYl9hZ2VudF9zdGF0dXMucHkiKSwKICAgICgibG9jYWwtd2ViLXNlYXJjaC9z
>> "!B64TMP!" echo Y3JpcHRzL3dlYl9pbnRlcmFjdC5weSIsICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2Vi
>> "!B64TMP!" echo X2ludGVyYWN0LnB5IiksCiAgICAoImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfaW50ZXJh
>> "!B64TMP!" echo Y3Rfc3RvcC5weSIsICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2ludGVyYWN0X3N0b3Au
>> "!B64TMP!" echo cHkiKSwKICAgICgibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9wYXJzZS5weSIsICAgICAg
>> "!B64TMP!" echo ICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3BhcnNlLnB5IiksCiAgICAoImxvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9jcmVhdGUucHkiLCAibG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aC9zY3JpcHRzL3dlYl9tb25pdG9yX2NyZWF0ZS5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo L3NjcmlwdHMvd2ViX21vbml0b3JfbGlzdC5weSIsICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfbW9uaXRvcl9saXN0LnB5IiksCiAgICAoImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfbW9uaXRvcl9nZXQucHkiLCAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25p
>> "!B64TMP!" echo dG9yX2dldC5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3Jf
>> "!B64TMP!" echo dXBkYXRlLnB5IiwgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl91cGRhdGUu
>> "!B64TMP!" echo cHkiKSwKICAgICgibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9yX2RlbGV0ZS5w
>> "!B64TMP!" echo eSIsICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfZGVsZXRlLnB5IiksCiAg
>> "!B64TMP!" echo ICAoImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9ydW4ucHkiLCAgICAibG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tb25pdG9yX3J1bi5weSIpLAogICAgKCJsb2NhbC13
>> "!B64TMP!" echo ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfY2hlY2tzLnB5IiwgImxvY2FsLXdlYi1zZWFy
>> "!B64TMP!" echo Y2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9jaGVja3MucHkiKSwKICAgICgibG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aC9zY3JpcHRzL3dlYl9tb25pdG9yX2NoZWNrLnB5IiwgICJsb2NhbC13ZWItc2VhcmNoL3Njcmlw
>> "!B64TMP!" echo dHMvd2ViX21vbml0b3JfY2hlY2sucHkiKSwKICAgICgibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9yZXNlYXJjaF9zZWFyY2gucHkiLCAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2Vi
>> "!B64TMP!" echo X3Jlc2VhcmNoX3NlYXJjaC5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2Vi
>> "!B64TMP!" echo X3Jlc2VhcmNoX2luc3BlY3QucHkiLCAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfcmVz
>> "!B64TMP!" echo ZWFyY2hfaW5zcGVjdC5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3Jl
>> "!B64TMP!" echo c2VhcmNoX3JlbGF0ZWQucHkiLCAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFy
>> "!B64TMP!" echo Y2hfcmVsYXRlZC5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3Jlc2Vh
>> "!B64TMP!" echo cmNoX3JlYWQucHkiLCAgICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hf
>> "!B64TMP!" echo cmVhZC5weSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2dpdGh1Yl9zZWFy
>> "!B64TMP!" echo Y2gucHkiLCAgICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfZ2l0aHViX3NlYXJjaC5w
>> "!B64TMP!" echo eSIpLAogICAgKCJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2RldmVsb3Blcl9zZWFyY2gu
>> "!B64TMP!" echo cHkiLCAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSIp
>> "!B64TMP!" echo LAogICAgKCJpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQiLCAgICAgICAgICAgICAiaW5zdGFsbC1s
>> "!B64TMP!" echo b2NhbC1zZWFyY2guYmF0IiksCl0KCgojIFRoZSAxOSBhY2NvdW50LWdhdGVkIHRvb2wgc2NyaXB0
>> "!B64TMP!" echo czogdGhleSBvbmx5IHdvcmsgYWdhaW5zdCBhIEZpcmVjcmF3bAojIGFjY291bnQgKHRoZSBjbG91
>> "!B64TMP!" echo ZCBBUEkpLCBzbyB0aGUgaW5zdGFsbGVycyBhc2sgYSB5L04gIkFkZCBhIEZpcmVjcmF3bAojIGFj
>> "!B64TMP!" echo Y291bnQ/IiBxdWVzdGlvbiAoZGVmYXVsdCBOKSBhbmQsIHdoZW4gYW5zd2VyZWQgTiwgZGVsZXRl
>> "!B64TMP!" echo IHRoZXNlIHNjcmlwdHMKIyBmcm9tIHRoZSBidW5kbGVkIHNraWxsIGFuZCBzd2FwIGluIHRoZSBj
>> "!B64TMP!" echo b3JlLW9ubHkgU0tJTEwubWQgKFNLSUxMLWNvcmUubWQpLgpBQ0NPVU5UX1RPT0xTID0gWwogICAg
>> "!B64TMP!" echo IndlYl9hZ2VudC5weSIsICJ3ZWJfYWdlbnRfc3RhdHVzLnB5IiwKICAgICJ3ZWJfaW50ZXJhY3Qu
>> "!B64TMP!" echo cHkiLCAid2ViX2ludGVyYWN0X3N0b3AucHkiLAogICAgIndlYl9wYXJzZS5weSIsCiAgICAid2Vi
>> "!B64TMP!" echo X21vbml0b3JfY3JlYXRlLnB5IiwgIndlYl9tb25pdG9yX2xpc3QucHkiLCAid2ViX21vbml0b3Jf
>> "!B64TMP!" echo Z2V0LnB5IiwKICAgICJ3ZWJfbW9uaXRvcl91cGRhdGUucHkiLCAid2ViX21vbml0b3JfZGVsZXRl
>> "!B64TMP!" echo LnB5IiwgIndlYl9tb25pdG9yX3J1bi5weSIsCiAgICAid2ViX21vbml0b3JfY2hlY2tzLnB5Iiwg
>> "!B64TMP!" echo IndlYl9tb25pdG9yX2NoZWNrLnB5IiwKICAgICJ3ZWJfcmVzZWFyY2hfc2VhcmNoLnB5IiwgIndl
>> "!B64TMP!" echo Yl9yZXNlYXJjaF9pbnNwZWN0LnB5IiwKICAgICJ3ZWJfcmVzZWFyY2hfcmVsYXRlZC5weSIsICJ3
>> "!B64TMP!" echo ZWJfcmVzZWFyY2hfcmVhZC5weSIsCiAgICAid2ViX2dpdGh1Yl9zZWFyY2gucHkiLCAid2ViX2Rl
>> "!B64TMP!" echo dmVsb3Blcl9zZWFyY2gucHkiLApdCgoKZGVmIHJlYWQocmVsKToKICAgIHdpdGggb3Blbihvcy5w
>> "!B64TMP!" echo YXRoLmpvaW4oU1JDLCByZWwpLCAicmIiKSBhcyBmOgogICAgICAgIHJldHVybiBmLnJlYWQoKQoK
>> "!B64TMP!" echo CiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT0KIyAgV2luZG93cyBpbnN0YWxsZXIgKC5iYXQpCiMgPT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT0KCmRlZiBiNjRfY2h1bmtlZChkYXRhLCB3aWR0aD03Nik6CiAgICAi
>> "!B64TMP!" echo IiJSZXR1cm4gbGlzdCBvZiA8PXdpZHRoLWNoYXIgYmFzZTY0IGxpbmVzLiIiIgogICAgcyA9IGJh
>> "!B64TMP!" echo c2U2NC5iNjRlbmNvZGUoZGF0YSkuZGVjb2RlKCJhc2NpaSIpCiAgICByZXR1cm4gW3NbaTppK3dp
>> "!B64TMP!" echo ZHRoXSBmb3IgaSBpbiByYW5nZSgwLCBsZW4ocyksIHdpZHRoKV0KCgpkZWYgZ2VuX2JhdCgpOgog
>> "!B64TMP!" echo ICAgb3V0ID0gW10KICAgIGFwID0gb3V0LmFwcGVuZAoKICAgIGFwKCdAZWNobyBvZmYnKQogICAg
>> "!B64TMP!" echo YXAoJ3NldGxvY2FsIGVuYWJsZURlbGF5ZWRFeHBhbnNpb24nKQogICAgYXAoJ2NoY3AgNjUwMDEg
>> "!B64TMP!" echo Pm51bCcpCiAgICBhcCgndGl0bGUgTG9jYWwgU2VhcmNoIC0gSW5zdGFsbGVyJykKICAgIGFwKCcn
>> "!B64TMP!" echo KQogICAgYXAoJ1JFTSA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJ1JFTSAgTG9jYWwgU2Vh
>> "!B64TMP!" echo cmNoIEluc3RhbGxlciAgKEZpcmVjcmF3bCArIFNlYXJYTkcgKyBsb2NhbC13ZWItc2VhcmNoIHNr
>> "!B64TMP!" echo aWxsKSAgLSAgV2luZG93cycpCiAgICBhcCgnUkVNID09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBh
>> "!B64TMP!" echo cCgnUkVNICBTZWxmLWNvbnRhaW5lZDogZXZlcnkgZmlsZSB0aGUgaW5zdGFsbGVyIG5lZWRzIGlz
>> "!B64TMP!" echo IGVtYmVkZGVkIGJlbG93IGFzJykKICAgIGFwKCdSRU0gIGJhc2U2NC4gSWYgYSBzb3VyY2UgZmls
>> "!B64TMP!" echo ZSBpcyBtaXNzaW5nIGZyb20gdGhpcyBzY3JpcHRcJ3MgZm9sZGVyIChlLmcuIHlvdScpCiAgICBh
>> "!B64TMP!" echo cCgnUkVNICBvbmx5IGRvd25sb2FkZWQgdGhpcyBvbmUgLmJhdCksIHRoZSBlbWJlZGRlZCBjb3B5
>> "!B64TMP!" echo IGlzIHVzZWQgaW5zdGVhZC4nKQogICAgYXAoJ1JFTSAgQWZ0ZXIgaW5zdGFsbGluZyB0aGUgc3Rh
>> "!B64TMP!" echo Y2sgaXQgYWxzbyBjb3BpZXMgdGhlIGJ1bmRsZWQgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCcpCiAg
>> "!B64TMP!" echo ICBhcCgnUkVNICBza2lsbCBpbnRvICVVU0VSUFJPRklMRSVcXC5hZ2VudHNcXHNraWxsc1xcbG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaC4nKQogICAgYXAoJ1JFTSAgVGhlIGluc3RhbGxlciBhc2tzIGEgeS9OICJB
>> "!B64TMP!" echo ZGQgYSBGaXJlY3Jhd2wgYWNjb3VudD8iIHF1ZXN0aW9uIChkZWZhdWx0IE4pOicpCiAgICBhcCgn
>> "!B64TMP!" echo UkVNICB3aXRob3V0IGFuIGFjY291bnQgb25seSB0aGUgZnJlZSBsb2NhbCBza2lsbCB0b29scyBh
>> "!B64TMP!" echo cmUgaW5zdGFsbGVkICh0aGUnKQogICAgYXAoJ1JFTSAgMTkgYWNjb3VudC1nYXRlZCBzY3JpcHRz
>> "!B64TMP!" echo IGFyZSBza2lwcGVkIGFuZCBhIGNvcmUtb25seSBTS0lMTC5tZCBpcyB1c2VkKTsnKQogICAgYXAo
>> "!B64TMP!" echo J1JFTSAgd2l0aCBvbmUgdGhlIGNyZWRlbnRpYWxzIGFyZSB3cml0dGVuIHRvIC5lbnYgYW5kIGFs
>> "!B64TMP!" echo bCAyNSB0b29scyBpbnN0YWxsLicpCiAgICBhcCgnUkVNICBJZiB0aGUgRG9ja2VyIGVuZ2luZSBp
>> "!B64TMP!" echo cyBub3QgcnVubmluZywgdGhlIGluc3RhbGxlciBsYXVuY2hlcyBEb2NrZXInKQogICAgYXAoJ1JF
>> "!B64TMP!" echo TSAgRGVza3RvcCBhdXRvbWF0aWNhbGx5IGFuZCB3YWl0cyBmb3IgaXQgYmVmb3JlIHB1bGxpbmcg
>> "!B64TMP!" echo aW1hZ2VzLicpCiAgICBhcCgnUkVNID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnJykKICAg
>> "!B64TMP!" echo IGFwKCdlY2hvID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PScpCiAgICBhcCgnZWNobyAgIExvY2FsIFNlYXJjaCBJbnN0YWxsZXIgIChG
>> "!B64TMP!" echo aXJlY3Jhd2wgKyBTZWFyWE5HICsgbG9jYWwtd2ViLXNlYXJjaCknKQogICAgYXAoJ2VjaG8gICBB
>> "!B64TMP!" echo IGxvY2FsIHdlYi1icm93c2luZyBzeXN0ZW0gZm9yIEFJIG1vZGVscy4nKQogICAgYXAoJ2VjaG8g
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09JykKICAgIGFwKCdlY2hvLicpCiAgICBhcCgnJykKICAgICMgRG9ja2VyIGNoZWNrIChhdXRv
>> "!B64TMP!" echo LWxhdW5jaCBEb2NrZXIgRGVza3RvcCB3aGVuIHRoZSBlbmdpbmUgaXMgZG93bikKICAgIGFwKCd3
>> "!B64TMP!" echo aGVyZSBkb2NrZXIgPm51bCAyPiYxJykKICAgIGFwKCdpZiBlcnJvcmxldmVsIDEgKCcpCiAgICBh
>> "!B64TMP!" echo cCgnICBlY2hvIFtFUlJPUl0gRG9ja2VyIHdhcyBub3QgZm91bmQgb24geW91ciBQQVRILicpCiAg
>> "!B64TMP!" echo ICBhcCgnICBlY2hvICAgSW5zdGFsbCBEb2NrZXIgRGVza3RvcDogaHR0cHM6Ly93d3cuZG9ja2Vy
>> "!B64TMP!" echo LmNvbS9wcm9kdWN0cy9kb2NrZXItZGVza3RvcC8nKQogICAgYXAoJyAgZWNobyAgIFRoZW4gcmUt
>> "!B64TMP!" echo cnVuIHRoaXMgaW5zdGFsbGVyLicpCiAgICBhcCgnICBwYXVzZSAmIGV4aXQgL2IgMScpCiAgICBh
>> "!B64TMP!" echo cCgnKScpCiAgICBhcCgnZG9ja2VyIGluZm8gPm51bCAyPiYxJykKICAgIGFwKCdpZiBub3QgZXJy
>> "!B64TMP!" echo b3JsZXZlbCAxIGdvdG8gZG9ja2VyX29rJykKICAgIGFwKCdlY2hvIFtOT1RFXSBUaGUgRG9ja2Vy
>> "!B64TMP!" echo IGVuZ2luZSBpcyBub3QgcnVubmluZyAtIHRyeWluZyB0byBzdGFydCBEb2NrZXIgRGVza3RvcC4u
>> "!B64TMP!" echo LicpCiAgICBhcCgnc2V0ICJERF9FWEU9IicpCiAgICBhcCgnaWYgZXhpc3QgIiVQcm9ncmFtRmls
>> "!B64TMP!" echo ZXMlXFxEb2NrZXJcXERvY2tlclxcRG9ja2VyIERlc2t0b3AuZXhlIiBzZXQgIkREX0VYRT0lUHJv
>> "!B64TMP!" echo Z3JhbUZpbGVzJVxcRG9ja2VyXFxEb2NrZXJcXERvY2tlciBEZXNrdG9wLmV4ZSInKQogICAgYXAo
>> "!B64TMP!" echo J2lmIG5vdCBkZWZpbmVkIEREX0VYRSBpZiBleGlzdCAiJVByb2dyYW1GaWxlcyh4ODYpJVxcRG9j
>> "!B64TMP!" echo a2VyXFxEb2NrZXJcXERvY2tlciBEZXNrdG9wLmV4ZSIgc2V0ICJERF9FWEU9JVByb2dyYW1GaWxl
>> "!B64TMP!" echo cyh4ODYpJVxcRG9ja2VyXFxEb2NrZXJcXERvY2tlciBEZXNrdG9wLmV4ZSInKQogICAgYXAoJ2lm
>> "!B64TMP!" echo IG5vdCBkZWZpbmVkIEREX0VYRSBpZiBleGlzdCAiJUxPQ0FMQVBQREFUQSVcXFByb2dyYW1zXFxE
>> "!B64TMP!" echo b2NrZXIgRGVza3RvcFxcRG9ja2VyIERlc2t0b3AuZXhlIiBzZXQgIkREX0VYRT0lTE9DQUxBUFBE
>> "!B64TMP!" echo QVRBJVxcUHJvZ3JhbXNcXERvY2tlciBEZXNrdG9wXFxEb2NrZXIgRGVza3RvcC5leGUiJykKICAg
>> "!B64TMP!" echo IGFwKCdpZiBub3QgZGVmaW5lZCBERF9FWEUgKCcpCiAgICBhcCgnICBlY2hvIFtFUlJPUl0gRG9j
>> "!B64TMP!" echo a2VyIERlc2t0b3Agd2FzIG5vdCBmb3VuZCBpbiB0aGUgdXN1YWwgaW5zdGFsbCBsb2NhdGlvbnMu
>> "!B64TMP!" echo JykKICAgIGFwKCcgIGVjaG8gICBTdGFydCBpdCBtYW51YWxseSwgd2FpdCB1bnRpbCBpdCBzYXlz
>> "!B64TMP!" echo ICJydW5uaW5nIiwgdGhlbiByZS1ydW4nKQogICAgYXAoJyAgZWNobyAgIHRoaXMgaW5zdGFsbGVy
>> "!B64TMP!" echo LicpCiAgICBhcCgnICBwYXVzZSAmIGV4aXQgL2IgMScpCiAgICBhcCgnKScpCiAgICBhcCgnZWNo
>> "!B64TMP!" echo byAgICAgTGF1bmNoaW5nOiAiIUREX0VYRSEiJykKICAgIGFwKCdzdGFydCAiIiAiIUREX0VYRSEi
>> "!B64TMP!" echo JykKICAgIGFwKCdzZXQgIkREX0xBVU5DSEVEPTEiJykKICAgIGFwKCdlY2hvICAgICBEb2NrZXIg
>> "!B64TMP!" echo RGVza3RvcCBpcyBzdGFydGluZyBpbiB0aGUgYmFja2dyb3VuZC4gQW5zd2VyIHRoZSBuZXh0JykK
>> "!B64TMP!" echo ICAgIGFwKCdlY2hvICAgICBxdWVzdGlvbnMgd2hpbGUgaXQgYm9vdHMgLSB0aGUgaW5zdGFsbGVy
>> "!B64TMP!" echo IHdhaXRzIGZvciB0aGUgZW5naW5lJykKICAgIGFwKCdlY2hvICAgICBiZWZvcmUgcHVsbGluZyBp
>> "!B64TMP!" echo bWFnZXMuJykKICAgIGFwKCc6ZG9ja2VyX29rJykKICAgIGFwKCdpZiBub3QgZGVmaW5lZCBERF9M
>> "!B64TMP!" echo QVVOQ0hFRCBlY2hvIFtPS10gRG9ja2VyIGlzIHJ1bm5pbmcuJykKICAgIGFwKCdlY2hvLicpCiAg
>> "!B64TMP!" echo ICBhcCgnJykKICAgICMgU291cmNlIGZvbGRlcgogICAgYXAoJ3NldCAiU1JDPSV+ZHAwIicpCiAg
>> "!B64TMP!" echo ICBhcCgnaWYgIiFTUkM6fi0xISI9PSJcXCIgc2V0ICJTUkM9IVNSQzp+MCwtMSEiJykKICAgIGFw
>> "!B64TMP!" echo KCcnKQogICAgIyBQcm9tcHRzCiAgICBhcCgnc2V0ICJERUZBVUxUX1RBUkdFVD0lVVNFUlBST0ZJ
>> "!B64TMP!" echo TEUlXFxsb2NhbC1zZWFyY2giJykKICAgIGFwKCcnKQogICAgYXAoJ2VjaG8gLS0tIFN0ZXAgMSBv
>> "!B64TMP!" echo ZiA1OiBJbnN0YWxsIGxvY2F0aW9uIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tJykKICAgIGFw
>> "!B64TMP!" echo KCdlY2hvICAgRGVmYXVsdDogJURFRkFVTFRfVEFSR0VUJScpCiAgICBhcCgnc2V0ICJUQVJHRVQ9
>> "!B64TMP!" echo IicpCiAgICBhcCgnc2V0IC9wIFRBUkdFVD0iICBUYXJnZXQgZm9sZGVyIFtwcmVzcyBFbnRlciBm
>> "!B64TMP!" echo b3IgZGVmYXVsdF06ICInKQogICAgYXAoJ2lmICIhVEFSR0VUISI9PSIiIHNldCAiVEFSR0VUPSVE
>> "!B64TMP!" echo RUZBVUxUX1RBUkdFVCUiJykKICAgIGFwKCdzZXQgIlRBUkdFVD0hVEFSR0VUOiI9ISInKQogICAg
>> "!B64TMP!" echo YXAoJ2ZvciAlJUkgaW4gKCIhVEFSR0VUISIpIGRvIHNldCAiVEFSR0VUPSUlfmZJIicpCiAgICBh
>> "!B64TMP!" echo cCgnZWNobyAgIFVzaW5nOiAhVEFSR0VUIScpCiAgICBhcCgnZWNoby4nKQogICAgYXAoJycpCiAg
>> "!B64TMP!" echo ICBhcCgnOmFza19zZWFyeG5nJykKICAgIGFwKCdlY2hvIC0tLSBTdGVwIDIgb2YgNTogU2VhclhO
>> "!B64TMP!" echo RyBwb3J0IChkZWZhdWx0IDk5OTApIC0tLS0tLS0tLS0tLS0tJykKICAgIGFwKCdzZXQgIlNFQVJY
>> "!B64TMP!" echo TkdfUE9SVD0iJykKICAgIGFwKCdzZXQgL3AgU0VBUlhOR19QT1JUPSIgIFBvcnQgZm9yIFNlYXJY
>> "!B64TMP!" echo TkcgW3ByZXNzIEVudGVyIGZvciA5OTkwXTogIicpCiAgICBhcCgnaWYgIiFTRUFSWE5HX1BPUlQh
>> "!B64TMP!" echo Ij09IiIgc2V0ICJTRUFSWE5HX1BPUlQ9OTk5MCInKQogICAgYXAoJ2NhbGwgOnZhbGlkYXRlX3Bv
>> "!B64TMP!" echo cnQgIiFTRUFSWE5HX1BPUlQhIicpCiAgICBhcCgnaWYgIWVycm9ybGV2ZWwhIG5lcSAwICggZWNo
>> "!B64TMP!" echo byAgIFtXQVJOSU5HXSAiIVNFQVJYTkdfUE9SVCEiIGlzIG5vdCBhIHZhbGlkIHBvcnQgXigxLTY1
>> "!B64TMP!" echo NTM1XikuICYgZWNoby4gJiBnb3RvIGFza19zZWFyeG5nICknKQogICAgYXAoJycpCiAgICBhcCgn
>> "!B64TMP!" echo OmFza19maXJlY3Jhd2wnKQogICAgYXAoJ2VjaG8gLS0tIFN0ZXAgMyBvZiA1OiBGaXJlY3Jhd2wg
>> "!B64TMP!" echo cG9ydCAoZGVmYXVsdCA5OTkxKSAtLS0tLS0tLS0tLS0nKQogICAgYXAoJ3NldCAiRklSRUNSQVdM
>> "!B64TMP!" echo X1BPUlQ9IicpCiAgICBhcCgnc2V0IC9wIEZJUkVDUkFXTF9QT1JUPSIgIFBvcnQgZm9yIEZpcmVj
>> "!B64TMP!" echo cmF3bCBbcHJlc3MgRW50ZXIgZm9yIDk5OTFdOiAiJykKICAgIGFwKCdpZiAiIUZJUkVDUkFXTF9Q
>> "!B64TMP!" echo T1JUISI9PSIiIHNldCAiRklSRUNSQVdMX1BPUlQ9OTk5MSInKQogICAgYXAoJ2NhbGwgOnZhbGlk
>> "!B64TMP!" echo YXRlX3BvcnQgIiFGSVJFQ1JBV0xfUE9SVCEiJykKICAgIGFwKCdpZiAhZXJyb3JsZXZlbCEgbmVx
>> "!B64TMP!" echo IDAgKCBlY2hvICAgW1dBUk5JTkddICIhRklSRUNSQVdMX1BPUlQhIiBpcyBub3QgYSB2YWxpZCBw
>> "!B64TMP!" echo b3J0IF4oMS02NTUzNV4pLiAmIGVjaG8uICYgZ290byBhc2tfZmlyZWNyYXdsICknKQogICAgYXAo
>> "!B64TMP!" echo J2lmIC9pICIhRklSRUNSQVdMX1BPUlQhIj09IiFTRUFSWE5HX1BPUlQhIiAoIGVjaG8gICBbV0FS
>> "!B64TMP!" echo TklOR10gRmlyZWNyYXdsIHBvcnQgbXVzdCBkaWZmZXIgZnJvbSBTZWFyWE5HIHBvcnQuICYgZWNo
>> "!B64TMP!" echo by4gJiBnb3RvIGFza19maXJlY3Jhd2wgKScpCiAgICBhcCgnJykKICAgIGFwKCdlY2hvLicpCiAg
>> "!B64TMP!" echo ICBhcCgnZWNobyAtLS0gU3RlcCA0IG9mIDU6IExvY2FsIExMTSAob3B0aW9uYWwpIC0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLScpCiAgICBhcCgnZWNobyAgIExldHMgRmlyZWNyYXdsIGRvIEFJIGV4dHJh
>> "!B64TMP!" echo Y3Rpb24gKC92MS9leHRyYWN0KSBhbmQgc3VtbWFyaWVzLicpCiAgICBhcCgnZWNobyAgIFJlY29t
>> "!B64TMP!" echo bWVuZGVkOiBMTSBTdHVkaW8gIC1ePiAgaHR0cDovL2xvY2FsaG9zdDoxMjM0L3YxJykKICAgIGFw
>> "!B64TMP!" echo KCdzZXQgIlVTRV9MTE09IicpCiAgICBhcCgnc2V0IC9wIFVTRV9MTE09IiAgQ29ubmVjdCBhIGxv
>> "!B64TMP!" echo Y2FsIExMTSBub3c/IFt5L05dOiAiJykKICAgIGFwKCdzZXQgIk9QRU5BSV9CQVNFX1VSTD0iJykK
>> "!B64TMP!" echo ICAgIGFwKCdzZXQgIk9QRU5BSV9BUElfS0VZPSInKQogICAgYXAoJ3NldCAiTU9ERUxfTkFNRT0i
>> "!B64TMP!" echo JykKICAgIGFwKCdpZiAvaSAiIVVTRV9MTE0hIj09InkiICgnKQogICAgYXAoJyAgc2V0ICJMTE1f
>> "!B64TMP!" echo VVJMPSInKQogICAgYXAoJyAgc2V0IC9wIExMTV9VUkw9IiAgICBMTSBTdHVkaW8gc2VydmVyIFVS
>> "!B64TMP!" echo TCBhcyBzaG93biBpbiBMTSBTdHVkaW8gW0VudGVyID0gaHR0cDovL2xvY2FsaG9zdDoxMjM0L3Yx
>> "!B64TMP!" echo XTogIicpCiAgICBhcCgnICBpZiAiIUxMTV9VUkwhIj09IiIgc2V0ICJMTE1fVVJMPWh0dHA6Ly9s
>> "!B64TMP!" echo b2NhbGhvc3Q6MTIzNC92MSInKQogICAgYXAoJyAgc2V0ICJMTE1fTU9ERUw9IicpCiAgICBhcCgn
>> "!B64TMP!" echo ICBzZXQgL3AgTExNX01PREVMPSIgICAgTW9kZWwgbmFtZSBsb2FkZWQgaW4gTE0gU3R1ZGlvIFtF
>> "!B64TMP!" echo bnRlciB0byBza2lwXTogIicpCiAgICBhcCgnICBzZXQgIk9QRU5BSV9CQVNFX1VSTD0hTExNX1VS
>> "!B64TMP!" echo TCEiJykKICAgIGFwKCcgIHNldCAiT1BFTkFJX0JBU0VfVVJMPSFPUEVOQUlfQkFTRV9VUkw6aHR0
>> "!B64TMP!" echo cDovL2xvY2FsaG9zdD1odHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWwhIicpCiAgICBhcCgnICBz
>> "!B64TMP!" echo ZXQgIk9QRU5BSV9CQVNFX1VSTD0hT1BFTkFJX0JBU0VfVVJMOmh0dHA6Ly8xMjcuMC4wLjE9aHR0
>> "!B64TMP!" echo cDovL2hvc3QuZG9ja2VyLmludGVybmFsISInKQogICAgYXAoJyAgc2V0ICJPUEVOQUlfQVBJX0tF
>> "!B64TMP!" echo WT1sbS1zdHVkaW8iJykKICAgIGFwKCcgIGlmIG5vdCAiIUxMTV9NT0RFTCEiPT0iIiBzZXQgIk1P
>> "!B64TMP!" echo REVMX05BTUU9IUxMTV9NT0RFTCEiJykKICAgIGFwKCcgIGVjaG8gICAgIF4oQ29udGFpbmVyIHdp
>> "!B64TMP!" echo bGwgcmVhY2ggaXQgYXQ6ICFPUEVOQUlfQkFTRV9VUkwhXiknKQogICAgYXAoJyAgZWNobyAgICAg
>> "!B64TMP!" echo XihNYWtlIHN1cmUgTE0gU3R1ZGlvIGhhcyAiU2VydmUgb24gbG9jYWwgbmV0d29yayIgZW5hYmxl
>> "!B64TMP!" echo ZC5eKScpCiAgICBhcCgnKScpCiAgICBhcCgnJykKICAgICMgU3RlcCA1OiBvcHRpb25hbCBGaXJl
>> "!B64TMP!" echo Y3Jhd2wgYWNjb3VudCAodW5sb2NrcyB0aGUgYWNjb3VudC1nYXRlZCB0b29scykKICAgICMgTk9U
>> "!B64TMP!" echo RTogZXZlcnkgZWNobyBsaW5lIG11c3QgY2FycnkgYmFsYW5jZWQgKG9yIF4tZXNjYXBlZCkgcGFy
>> "!B64TMP!" echo ZW5zIC0KICAgICMgYW4gdW5lc2NhcGVkIHVuYmFsYW5jZWQgIigiIG1ha2VzIHJlYWwgY21kLmV4
>> "!B64TMP!" echo ZSBzd2FsbG93IHRoZSBORVhUIGxpbmUKICAgICMgYXMgYSBjb250aW51YXRpb24gYW5kIGRpZSB3
>> "!B64TMP!" echo aXRoIGEgc3ludGF4IGVycm9yICh0aGUgd2luZG93IGp1c3QgY2xvc2VzKS4KICAgIGFwKCdlY2hv
>> "!B64TMP!" echo IC0tLSBTdGVwIDUgb2YgNTogRmlyZWNyYXdsIGFjY291bnQgKG9wdGlvbmFsKSAtLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tJykKICAgIGFwKCdlY2hvICAgVGhlIGV4dHJhIHRvb2xzIF4ocmVzZWFyY2ggYWdlbnQsIGxp
>> "!B64TMP!" echo dmUtcGFnZSBpbnRlcmFjdCwgZmlsZSBwYXJzZSwnKQogICAgYXAoJ2VjaG8gICBtb25pdG9ycywg
>> "!B64TMP!" echo cGFwZXIgcmVzZWFyY2gsIEdpdEh1Yi9kZXZlbG9wZXIgc2VhcmNoXikgb25seSB3b3JrJykKICAg
>> "!B64TMP!" echo IGFwKCdlY2hvICAgd2l0aCBhIEZpcmVjcmF3bCBhY2NvdW50IEFQSSBrZXkgXihwYWlkIGNsb3Vk
>> "!B64TMP!" echo IHNlcnZpY2VeKTonKQogICAgYXAoJ2VjaG8gICAgIGh0dHBzOi8vd3d3LmZpcmVjcmF3bC5kZXYn
>> "!B64TMP!" echo KQogICAgYXAoJ2VjaG8gICBBbnN3ZXIgTiB0byBpbnN0YWxsIG9ubHkgdGhlIGZyZWUgbG9jYWwg
>> "!B64TMP!" echo dG9vbHMgXihkZWZhdWx0XikuJykKICAgIGFwKCdzZXQgIlVTRV9GQz0iJykKICAgIGFwKCdzZXQg
>> "!B64TMP!" echo L3AgVVNFX0ZDPSIgIEFkZCBhIEZpcmVjcmF3bCBhY2NvdW50IG5vdz8gW3kvTl06ICInKQogICAg
>> "!B64TMP!" echo YXAoJ3NldCAiRkNfQVBJX0tFWT0iJykKICAgIGFwKCdzZXQgIkZDX0FQSV9VUkw9IicpCiAgICBh
>> "!B64TMP!" echo cCgnaWYgL2kgbm90ICIhVVNFX0ZDISI9PSJ5IiBnb3RvIGZjX2RvbmUnKQogICAgYXAoJ3NldCAi
>> "!B64TMP!" echo RkNfVFJJRVM9MCInKQogICAgYXAoJzphc2tfZmNrZXknKQogICAgYXAoJ3NldCAiRkNfQVBJX0tF
>> "!B64TMP!" echo WT0iJykKICAgIGFwKCdzZXQgL3AgRkNfQVBJX0tFWT0iICAgIEZpcmVjcmF3bCBBUEkga2V5IChm
>> "!B64TMP!" echo cm9tIGh0dHBzOi8vd3d3LmZpcmVjcmF3bC5kZXYpOiAiJykKICAgIGFwKCdpZiBub3QgIiFGQ19B
>> "!B64TMP!" echo UElfS0VZISI9PSIiIGdvdG8gZmNrZXlfb2snKQogICAgYXAoJ3NldCAvYSBGQ19UUklFUys9MScp
>> "!B64TMP!" echo CiAgICBhcCgnaWYgIUZDX1RSSUVTISBnZXEgMyAoJykKICAgIGFwKCcgIGVjaG8gICAgIFtXQVJO
>> "!B64TMP!" echo SU5HXSBObyBBUEkga2V5IGVudGVyZWQgLSBjb250aW51aW5nIFdJVEhPVVQgYSBGaXJlY3Jhd2wg
>> "!B64TMP!" echo YWNjb3VudC4nKQogICAgYXAoJyAgZ290byBmY19kb25lJykKICAgIGFwKCcpJykKICAgIGFwKCdl
>> "!B64TMP!" echo Y2hvICAgICBbV0FSTklOR10gVGhlIEFQSSBrZXkgY2Fubm90IGJlIGVtcHR5IC0gdHJ5IGFnYWlu
>> "!B64TMP!" echo LicpCiAgICBhcCgnZ290byBhc2tfZmNrZXknKQogICAgYXAoJzpmY2tleV9vaycpCiAgICBhcCgn
>> "!B64TMP!" echo c2V0ICJGQ19BUElfVVJMPSInKQogICAgYXAoJ3NldCAvcCBGQ19BUElfVVJMPSIgICAgRmlyZWNy
>> "!B64TMP!" echo YXdsIEFQSSBVUkwgW3ByZXNzIEVudGVyIGZvciBodHRwczovL2FwaS5maXJlY3Jhd2wuZGV2XTog
>> "!B64TMP!" echo IicpCiAgICBhcCgnaWYgIiFGQ19BUElfVVJMISI9PSIiIHNldCAiRkNfQVBJX1VSTD1odHRwczov
>> "!B64TMP!" echo L2FwaS5maXJlY3Jhd2wuZGV2IicpCiAgICBhcCgnOmZjX2RvbmUnKQogICAgYXAoJ2VjaG8uJykK
>> "!B64TMP!" echo ICAgICMgU3VtbWFyeSArIGNvbmZpcm0KICAgIGFwKCdlY2hvLicpCiAgICBhcCgnZWNobyA9PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0n
>> "!B64TMP!" echo KQogICAgYXAoJ2VjaG8gICBTdW1tYXJ5JykKICAgIGFwKCdlY2hvICAgRm9sZGVyOiAgICAgICAg
>> "!B64TMP!" echo ICFUQVJHRVQhJykKICAgIGFwKCdlY2hvICAgU2VhclhORyBwb3J0OiAgICFTRUFSWE5HX1BPUlQh
>> "!B64TMP!" echo JykKICAgIGFwKCdlY2hvICAgRmlyZWNyYXdsIHBvcnQ6ICFGSVJFQ1JBV0xfUE9SVCEnKQogICAg
>> "!B64TMP!" echo YXAoJ2VjaG8gICBBZ2VudCBza2lsbDogICAgJVVTRVJQUk9GSUxFJVxcLmFnZW50c1xcc2tpbGxz
>> "!B64TMP!" echo XFxsb2NhbC13ZWItc2VhcmNoJykKICAgIGFwKCdpZiBkZWZpbmVkIE9QRU5BSV9CQVNFX1VSTCAo
>> "!B64TMP!" echo JykKICAgIGFwKCcgIGVjaG8gICBMTE0gZW5kcG9pbnQ6ICAgIU9QRU5BSV9CQVNFX1VSTCEgICFN
>> "!B64TMP!" echo T0RFTF9OQU1FIScpCiAgICBhcCgnKSBlbHNlICgnKQogICAgYXAoJyAgZWNobyAgIExMTSBlbmRw
>> "!B64TMP!" echo b2ludDogICBeKG5vbmUgLSBlbmFibGUgbGF0ZXIgYnkgZWRpdGluZyAuZW52XiknKQogICAgYXAo
>> "!B64TMP!" echo JyknKQogICAgYXAoJ2lmIGRlZmluZWQgRkNfQVBJX0tFWSAoJykKICAgIGFwKCcgIGVjaG8gICBG
>> "!B64TMP!" echo aXJlY3Jhd2wgYWNjdDogIUZDX0FQSV9VUkwhICBeKGFjY291bnQgdG9vbHMgaW5zdGFsbGVkXikn
>> "!B64TMP!" echo KQogICAgYXAoJykgZWxzZSAoJykKICAgIGFwKCcgIGVjaG8gICBGaXJlY3Jhd2wgYWNjdDogXihu
>> "!B64TMP!" echo b25lIC0gZnJlZSBsb2NhbCB0b29scyBvbmx5XiknKQogICAgYXAoJyknKQogICAgYXAoJ2VjaG8g
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09JykKICAgIGFwKCdzZXQgIkNPTkZJUk09IicpCiAgICBhcCgnc2V0IC9wIENPTkZJUk09IlBy
>> "!B64TMP!" echo b2NlZWQgd2l0aCBpbnN0YWxsPyBbWS9uXTogIicpCiAgICBhcCgnaWYgL2kgIiFDT05GSVJNISI9
>> "!B64TMP!" echo PSJuIiAoIGVjaG8gSW5zdGFsbCBjYW5jZWxsZWQuICYgcGF1c2UgJiBleGl0IC9iIDAgKScpCiAg
>> "!B64TMP!" echo ICBhcCgnJykKICAgICMgQ3JlYXRlIGZvbGRlcnMKICAgIGFwKCdpZiBub3QgZXhpc3QgIiFUQVJH
>> "!B64TMP!" echo RVQhIiBta2RpciAiIVRBUkdFVCEiJykKICAgIGFwKCdpZiBub3QgZXhpc3QgIiFUQVJHRVQhXFxj
>> "!B64TMP!" echo b25maWdcXHNlYXJ4bmciIG1rZGlyICIhVEFSR0VUIVxcY29uZmlnXFxzZWFyeG5nIicpCiAgICBh
>> "!B64TMP!" echo cCgnaWYgbm90IGV4aXN0ICIhVEFSR0VUIVxcbG9jYWwtd2ViLXNlYXJjaFxcc2NyaXB0cyIgbWtk
>> "!B64TMP!" echo aXIgIiFUQVJHRVQhXFxsb2NhbC13ZWItc2VhcmNoXFxzY3JpcHRzIicpCiAgICBhcCgnJykKICAg
>> "!B64TMP!" echo ICMgQmFja3VwIGV4aXN0aW5nIC5lbnYKICAgIGFwKCdpZiBleGlzdCAiIVRBUkdFVCFcXC5lbnYi
>> "!B64TMP!" echo ICgnKQogICAgYXAoJyAgZm9yIC9mICJ1c2ViYWNrcSBkZWxpbXM9IiAlJXQgaW4gKGBwb3dlcnNo
>> "!B64TMP!" echo ZWxsIC1Ob1Byb2ZpbGUgLUNvbW1hbmQgIkdldC1EYXRlIC1Gb3JtYXQgeXl5eU1NZGRISG1tc3Mi
>> "!B64TMP!" echo YCkgZG8gc2V0ICJMRFQ9JSV0IicpCiAgICBhcCgnICBjb3B5IC9ZICIhVEFSR0VUIVxcLmVudiIg
>> "!B64TMP!" echo IiFUQVJHRVQhXFwuZW52LmJhay4hTERUISIgPm51bCcpCiAgICBhcCgnICBlY2hvICAgQmFja2Vk
>> "!B64TMP!" echo IHVwIGV4aXN0aW5nIC5lbnYgdG8gLmVudi5iYWsuIUxEVCEnKQogICAgYXAoJyknKQogICAgYXAo
>> "!B64TMP!" echo JycpCiAgICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0KICAgICMgIE1hdGVyaWFsaXNlIGV2ZXJ5IHByb2plY3QgZmls
>> "!B64TMP!" echo ZTogY29weSBmcm9tIHNvdXJjZSBpZiBwcmVzZW50LCBlbHNlCiAgICAjICBkZWNvZGUgdGhlIGVt
>> "!B64TMP!" echo YmVkZGVkIGJhc2U2NCBibG9iIGZvciB0aGF0IGZpbGUuCiAgICAjIC0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAgIGFw
>> "!B64TMP!" echo KCdlY2hvIENvcHlpbmcgZmlsZXMuLi4nKQoKICAgIGZvciByZWwsIHNyYyBpbiBGSUxFUzoKICAg
>> "!B64TMP!" echo ICAgICBpZiByZWwgPT0gImluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCI6CiAgICAgICAgICAgICMg
>> "!B64TMP!" echo VGhlIC5iYXQgY29waWVzIElUU0VMRiBhdCBydW50aW1lIHZpYSAlfmYwIChzZWUgYmVsb3cpLiBE
>> "!B64TMP!" echo byBub3QKICAgICAgICAgICAgIyBlbWJlZCBpdHNlbGYgaGVyZSAtLSB0aGF0IHdvdWxkIHJlYWQg
>> "!B64TMP!" echo YSBzdGFsZSBwcmV2aW91cy1nZW5lcmF0aW9uCiAgICAgICAgICAgICMgLmJhdCBhbmQgY3JlYXRl
>> "!B64TMP!" echo IGEgY29uZnVzaW5nIGR1cGxpY2F0ZS4KICAgICAgICAgICAgY29udGludWUKICAgICAgICBkYXRh
>> "!B64TMP!" echo ID0gcmVhZChzcmMpCiAgICAgICAgbGluZXMgPSBiNjRfY2h1bmtlZChkYXRhKQogICAgICAgIHJl
>> "!B64TMP!" echo bF93aW4gPSByZWwucmVwbGFjZSgiLyIsICJcXCIpCiAgICAgICAgYXAoJycpCiAgICAgICAgYXAo
>> "!B64TMP!" echo J1JFTSAtLS0gJyArIHJlbCArICcgLS0tJykKICAgICAgICBhcCgnc2V0ICJORUVEX0I2ND0xIicp
>> "!B64TMP!" echo CiAgICAgICAgYXAoJ2lmIGV4aXN0ICIhU1JDIVxcJyArIHJlbF93aW4gKyAnIiAoJykKICAgICAg
>> "!B64TMP!" echo ICBhcCgnICBjb3B5IC9ZICIhU1JDIVxcJyArIHJlbF93aW4gKyAnIiAiIVRBUkdFVCFcXCcgKyBy
>> "!B64TMP!" echo ZWxfd2luICsgJyIgPm51bCAyPiYxJykKICAgICAgICBhcCgnICBpZiBleGlzdCAiIVRBUkdFVCFc
>> "!B64TMP!" echo XCcgKyByZWxfd2luICsgJyIgc2V0ICJORUVEX0I2ND0wIicpCiAgICAgICAgYXAoJyknKQogICAg
>> "!B64TMP!" echo ICAgIGFwKCdpZiAiIU5FRURfQjY0ISI9PSIxIiAoJykKICAgICAgICBhcCgnICBlY2hvICAgW2Vt
>> "!B64TMP!" echo YmVkZGVkXSAnICsgcmVsICsgJyAgXihzb3VyY2Ugbm90IGZvdW5kIG5leHQgdG8gaW5zdGFsbGVy
>> "!B64TMP!" echo OyB1c2luZyBidWlsdC1pbiBjb3B5XiknKQogICAgICAgICMgRGV0ZXJtaW5pc3RpYyB0ZW1wLWZp
>> "!B64TMP!" echo bGUgdGFnIGRlcml2ZWQgZnJvbSB0aGUgZmlsZSBwYXRoIChDUkMzMikuCiAgICAgICAgIyBNdXN0
>> "!B64TMP!" echo IGJlIHN0YWJsZSBhY3Jvc3MgZ2VuIHJ1bnMgc28gdGhlIC5iYXQgZW1iZWRkZWQgaW5zaWRlIHRo
>> "!B64TMP!" echo ZSAuc2gKICAgICAgICAjIG1hdGNoZXMgdGhlIHN0YW5kYWxvbmUgLmJhdCBieXRlLWZvci1ieXRl
>> "!B64TMP!" echo LgogICAgICAgIGltcG9ydCB6bGliCiAgICAgICAgdGFnID0gIkxTIiArIHN0cih6bGliLmNyYzMy
>> "!B64TMP!" echo KHJlbC5lbmNvZGUoInV0Zi04IikpICYgMHhGRkZGRkZGRikKICAgICAgICBhcCgnICBzZXQgIkI2
>> "!B64TMP!" echo NFRNUD0lVEVNUCVcXCcgKyB0YWcgKyAnLmI2NCInKQogICAgICAgIGZpcnN0ID0gVHJ1ZQogICAg
>> "!B64TMP!" echo ICAgIGZvciBsbiBpbiBsaW5lczoKICAgICAgICAgICAgb3AgPSAnPicgaWYgZmlyc3QgZWxzZSAn
>> "!B64TMP!" echo Pj4nCiAgICAgICAgICAgIGFwKCcgICcgKyBvcCArICcgIiFCNjRUTVAhIiBlY2hvICcgKyBsbikK
>> "!B64TMP!" echo ICAgICAgICAgICAgZmlyc3QgPSBGYWxzZQogICAgICAgIGFwKCcgIHNldCAiTFNfQjY0X0lOPSFC
>> "!B64TMP!" echo NjRUTVAhIicpCiAgICAgICAgYXAoJyAgc2V0ICJMU19CNjRfT1VUPSFUQVJHRVQhXFwnICsgcmVs
>> "!B64TMP!" echo X3dpbiArICciJykKICAgICAgICBhcCgnICBjYWxsIDpkZWNvZGVfYjY0JykKICAgICAgICBhcCgn
>> "!B64TMP!" echo ICBpZiBleGlzdCAiIUI2NFRNUCEiIGRlbCAvUSAiIUI2NFRNUCEiID5udWwgMj4mMScpCiAgICAg
>> "!B64TMP!" echo ICAgYXAoJyknKQoKICAgICMgSW5jbHVkZSB0aGUgaW5zdGFsbGVycyB0aGVtc2VsdmVzIHNvIHRo
>> "!B64TMP!" echo ZSBmb2xkZXIgaXMgc2VsZi1jb250YWluZWQgLyByZS1pbnN0YWxsYWJsZQogICAgYXAoJ2lmIGV4
>> "!B64TMP!" echo aXN0ICIhU1JDIVxcaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IiBjb3B5IC9ZICIhU1JDIVxcaW5z
>> "!B64TMP!" echo dGFsbC1sb2NhbC1zZWFyY2guYmF0IiAiIVRBUkdFVCFcXGluc3RhbGwtbG9jYWwtc2VhcmNoLmJh
>> "!B64TMP!" echo dCIgPm51bCAyPiYxJykKICAgIGFwKCdpZiBleGlzdCAiIVNSQyFcXGluc3RhbGwtbG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoLnNoIiAgY29weSAvWSAiIVNSQyFcXGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIiAgIiFUQVJH
>> "!B64TMP!" echo RVQhXFxpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaCIgID5udWwgMj4mMScpCiAgICBhcCgnUkVNIEFs
>> "!B64TMP!" echo d2F5cyBhbHNvIGRyb3AgdGhlICpjdXJyZW50KiBpbnN0YWxsZXIgKHRoaXMgc2NyaXB0KSBpbnRv
>> "!B64TMP!" echo IHRhcmdldCwgZXZlbiBpZicpCiAgICBhcCgnUkVNIHRoZSBzb3VyY2UgY29weSBhYm92ZSB3YXMg
>> "!B64TMP!" echo c2tpcHBlZCAoZS5nLiB1c2VyIHJhbiBhIHJlbmFtZWQgY29weSBvZiB0aGUgYmF0KS4nKQogICAg
>> "!B64TMP!" echo YXAoJ2NvcHkgL1kgIiV+ZjAiICIhVEFSR0VUIVxcaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IiA+
>> "!B64TMP!" echo bnVsIDI+JjEnKQogICAgYXAoJycpCiAgICAjIEdlbmVyYXRlIHNlY3JldHMKICAgIGFwKCdlY2hv
>> "!B64TMP!" echo IEdlbmVyYXRpbmcgc2VjdXJlIGNyZWRlbnRpYWxzLi4uJykKICAgIGFwKCdjYWxsIDpnZW5rZXkg
>> "!B64TMP!" echo U0VDUkVUJykKICAgIGFwKCdjYWxsIDpnZW5rZXkgQlVMTCcpCiAgICBhcCgnY2FsbCA6Z2Vua2V5
>> "!B64TMP!" echo IFBHUEFTUycpCiAgICBhcCgnY2FsbCA6Z2Vua2V5IFJBQlBBU1MnKQogICAgYXAoJ2NhbGwgOmdl
>> "!B64TMP!" echo bmtleSBCTEVTU1RPS0VOJykKICAgIGFwKCcnKQogICAgIyBXcml0ZSAuZW52CiAgICBhcCgnZWNo
>> "!B64TMP!" echo byBXcml0aW5nIC5lbnYgLi4uJykKICAgIGFwKCc+ICIhVEFSR0VUIVxcLmVudiIgZWNobyAjIExv
>> "!B64TMP!" echo Y2FsIFNlYXJjaCBjb25maWd1cmF0aW9uIC0gZ2VuZXJhdGVkIGJ5IGluc3RhbGwtbG9jYWwtc2Vh
>> "!B64TMP!" echo cmNoLmJhdCcpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvICMgRWRpdCBwb3J0cy9M
>> "!B64TMP!" echo TE0gaGVyZSwgdGhlbiBydW4gVXBkYXRlLmJhdCB0byBhcHBseS4nKQogICAgYXAoJz4+ICIhVEFS
>> "!B64TMP!" echo R0VUIVxcLmVudiIgZWNoby4nKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyAjIC0t
>> "!B64TMP!" echo LS0gSG9zdCBwb3J0cyAtLS0tJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8gU0VB
>> "!B64TMP!" echo UlhOR19QT1JUPSFTRUFSWE5HX1BPUlQhJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYiIGVj
>> "!B64TMP!" echo aG8gRklSRUNSQVdMX1BPUlQ9IUZJUkVDUkFXTF9QT1JUIScpCiAgICBhcCgnPj4gIiFUQVJHRVQh
>> "!B64TMP!" echo XFwuZW52IiBlY2hvLicpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvICMgLS0tLSBT
>> "!B64TMP!" echo ZWFyWE5HIGluc3RhbmNlIHNlY3JldCAtLS0tJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5lbnYi
>> "!B64TMP!" echo IGVjaG8gU0VBUlhOR19TRUNSRVQ9IVNFQ1JFVCEnKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVu
>> "!B64TMP!" echo diIgZWNoby4nKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyAjIC0tLS0gRmlyZWNy
>> "!B64TMP!" echo YXdsIGludGVybmFsIGNyZWRlbnRpYWxzIC0tLS0nKQogICAgYXAoJz4+ICIhVEFSR0VUIVxcLmVu
>> "!B64TMP!" echo diIgZWNobyBCVUxMX0FVVEhfS0VZPSFCVUxMIScpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52
>> "!B64TMP!" echo IiBlY2hvIFBPU1RHUkVTX0RCPWZpcmVjcmF3bCcpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52
>> "!B64TMP!" echo IiBlY2hvIFBPU1RHUkVTX1VTRVI9ZmlyZWNyYXdsJykKICAgIGFwKCc+PiAiIVRBUkdFVCFcXC5l
>> "!B64TMP!" echo bnYiIGVjaG8gUE9TVEdSRVNfUEFTU1dPUkQ9IVBHUEFTUyEnKQogICAgYXAoJz4+ICIhVEFSR0VU
>> "!B64TMP!" echo IVxcLmVudiIgZWNobyBSQUJCSVRNUV9VU0VSPWZpcmVjcmF3bCcpCiAgICBhcCgnPj4gIiFUQVJH
>> "!B64TMP!" echo RVQhXFwuZW52IiBlY2hvIFJBQkJJVE1RX1BBU1NXT1JEPSFSQUJQQVNTIScpCiAgICBhcCgnPj4g
>> "!B64TMP!" echo IiFUQVJHRVQhXFwuZW52IiBlY2hvLicpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hv
>> "!B64TMP!" echo ICMgLS0tLSBCcm93c2VybGVzcyAoc3RlYWx0aCBoZWFkbGVzcyBDaHJvbWl1bSkgLS0tLScpCiAg
>> "!B64TMP!" echo ICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvIEJST1dTRVJMRVNTX1RPS0VOPSFCTEVTU1RP
>> "!B64TMP!" echo S0VOIScpCiAgICBhcCgnPj4gIiFUQVJHRVQhXFwuZW52IiBlY2hvLicpCiAgICBhcCgnPj4gIiFU
>> "!B64TMP!" echo QVJHRVQhXFwuZW52IiBlY2hvIExPR0dJTkdfTEVWRUw9aW5mbycpCiAgICBhcCgnaWYgZGVmaW5l
>> "!B64TMP!" echo ZCBPUEVOQUlfQkFTRV9VUkwgKCcpCiAgICBhcCgnICA+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8u
>> "!B64TMP!" echo JykKICAgIGFwKCcgID4+ICIhVEFSR0VUIVxcLmVudiIgZWNobyAjIC0tLS0gTG9jYWwgTExNIGZv
>> "!B64TMP!" echo ciBGaXJlY3Jhd2wgQUkgZmVhdHVyZXMgLS0tLScpCiAgICBhcCgnICA+PiAiIVRBUkdFVCFcXC5l
>> "!B64TMP!" echo bnYiIGVjaG8gT1BFTkFJX0JBU0VfVVJMPSFPUEVOQUlfQkFTRV9VUkwhJykKICAgIGFwKCcgID4+
>> "!B64TMP!" echo ICIhVEFSR0VUIVxcLmVudiIgZWNobyBPUEVOQUlfQVBJX0tFWT0hT1BFTkFJX0FQSV9LRVkhJykK
>> "!B64TMP!" echo ICAgIGFwKCcgIGlmIGRlZmluZWQgTU9ERUxfTkFNRSA+PiAiIVRBUkdFVCFcXC5lbnYiIGVjaG8g
>> "!B64TMP!" echo TU9ERUxfTkFNRT0hTU9ERUxfTkFNRSEnKQogICAgYXAoJyknKQogICAgYXAoJ2lmIGRlZmluZWQg
>> "!B64TMP!" echo RkNfQVBJX0tFWSAoJykKICAgIGFwKCcgID4+ICIhVEFSR0VUIVxcLmVudiIgZWNoby4nKQogICAg
>> "!B64TMP!" echo IyBOT1RFOiB0aGlzIGVjaG8gbGluZSBsaXZlcyBJTlNJREUgdGhlIGBpZiBkZWZpbmVkIEZDX0FQ
>> "!B64TMP!" echo SV9LRVkgKCAuLi4gKWAKICAgICMgYmxvY2suIEluIGNtZCBibG9jayBwYXJzaW5nLCBhbiB1bnF1
>> "!B64TMP!" echo b3RlZC91bmVzY2FwZWQgIikiIGluIGVjaG8gdGV4dAogICAgIyBDTE9TRVMgVEhFIEJMT0NLIEVB
>> "!B64TMP!" echo UkxZICggIigiIGluIHRleHQgaXMgaW5lcnQsICIpIiBpcyBzdHJ1Y3R1cmFsICksCiAgICAjIHNv
>> "!B64TMP!" echo ICIoY2xvdWQgQVBJKSIgd291bGQgZW5kIHRoZSBibG9jayBhdCAiQVBJKSIgYW5kIHRoZSByZXN0
>> "!B64TMP!" echo IG9mIHRoZQogICAgIyBsaW5lIGJlY29tZXMgYSB0b3AtbGV2ZWwgY29tbWFuZCAtPiAiRk9SIHdh
>> "!B64TMP!" echo cyB1bmV4cGVjdGVkIGF0IHRoaXMgdGltZSIKICAgICMgLT4gcmVhbCBjbWQuZXhlIGFib3J0cyB0
>> "!B64TMP!" echo aGUgd2hvbGUgaW5zdGFsbGVyLiBFc2NhcGUgYm90aCBwYXJlbnMuCiAgICBhcCgnICA+PiAiIVRB
>> "!B64TMP!" echo UkdFVCFcXC5lbnYiIGVjaG8gIyAtLS0tIEZpcmVjcmF3bCBhY2NvdW50IF4oY2xvdWQgQVBJXikg
>> "!B64TMP!" echo Zm9yIGFjY291bnQtb25seSB0b29scyAtLS0tJykKICAgIGFwKCcgID4+ICIhVEFSR0VUIVxcLmVu
>> "!B64TMP!" echo diIgZWNobyBGSVJFQ1JBV0xfQVBJX1VSTD0hRkNfQVBJX1VSTCEnKQogICAgYXAoJyAgPj4gIiFU
>> "!B64TMP!" echo QVJHRVQhXFwuZW52IiBlY2hvIEZJUkVDUkFXTF9BUElfS0VZPSFGQ19BUElfS0VZIScpCiAgICBh
>> "!B64TMP!" echo cCgnKScpCiAgICBhcCgnJykKICAgICMgSW5qZWN0IFNlYXJYTkcgc2VjcmV0IGludG8gc2V0dGlu
>> "!B64TMP!" echo Z3MueW1sCiAgICBhcCgnZWNobyBJbmplY3RpbmcgU2VhclhORyBzZWNyZXQgaW50byBzZXR0aW5n
>> "!B64TMP!" echo cy55bWwgLi4uJykKICAgIGFwKCdwb3dlcnNoZWxsIC1Ob1Byb2ZpbGUgLUNvbW1hbmQgIihHZXQt
>> "!B64TMP!" echo Q29udGVudCAtUmF3IFwnIVRBUkdFVCFcXGNvbmZpZ1xcc2VhcnhuZ1xcc2V0dGluZ3MueW1sXCcp
>> "!B64TMP!" echo IC1yZXBsYWNlIFwnX19TRUFSWE5HX1NFQ1JFVF9QTEFDRUhPTERFUl9fXCcsIFwnIVNFQ1JFVCFc
>> "!B64TMP!" echo JyB8IFNldC1Db250ZW50IC1Ob05ld2xpbmUgXCchVEFSR0VUIVxcY29uZmlnXFxzZWFyeG5nXFxz
>> "!B64TMP!" echo ZXR0aW5ncy55bWxcJyInKQogICAgYXAoJycpCiAgICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAgICMgIENvcmUt
>> "!B64TMP!" echo b25seSB0cmltOiB3aXRob3V0IGEgRmlyZWNyYXdsIGFjY291bnQsIHJlbW92ZSB0aGUgMTkKICAg
>> "!B64TMP!" echo ICMgIGFjY291bnQtZ2F0ZWQgc2NyaXB0cyBmcm9tIHRoZSBidW5kbGVkIHNraWxsIGFuZCBzd2Fw
>> "!B64TMP!" echo IGluIHRoZQogICAgIyAgY29yZS1vbmx5IFNLSUxMLm1kIHNvIHRoZSBpbnN0YWxsZWQgc2tpbGwg
>> "!B64TMP!" echo bWF0Y2hlcyB3aGF0IHdvcmtzLgogICAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgICBhcCgnaWYgZGVmaW5lZCBG
>> "!B64TMP!" echo Q19BUElfS0VZIGdvdG8gc2tpbGxfZnVsbCcpCiAgICBhcCgnZWNobyBJbnN0YWxsaW5nIHRoZSBj
>> "!B64TMP!" echo b3JlLW9ubHkgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCAobm8gRmlyZWNyYXdsIGFjY291bnQpLi4u
>> "!B64TMP!" echo JykKICAgIGZvciBuYW1lIGluIEFDQ09VTlRfVE9PTFM6CiAgICAgICAgcmVsX3dpbiA9ICJsb2Nh
>> "!B64TMP!" echo bC13ZWItc2VhcmNoXFxzY3JpcHRzXFwiICsgbmFtZQogICAgICAgIGFwKCdpZiBleGlzdCAiIVRB
>> "!B64TMP!" echo UkdFVCFcXCcgKyByZWxfd2luICsgJyIgZGVsIC9RICIhVEFSR0VUIVxcJyArIHJlbF93aW4gKyAn
>> "!B64TMP!" echo IiA+bnVsIDI+JjEnKQogICAgYXAoJ2lmIGV4aXN0ICIhVEFSR0VUIVxcbG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aFxcU0tJTEwtY29yZS5tZCIgY29weSAvWSAiIVRBUkdFVCFcXGxvY2FsLXdlYi1zZWFyY2hcXFNL
>> "!B64TMP!" echo SUxMLWNvcmUubWQiICIhVEFSR0VUIVxcbG9jYWwtd2ViLXNlYXJjaFxcU0tJTEwubWQiID5udWwn
>> "!B64TMP!" echo KQogICAgYXAoJzpza2lsbF9mdWxsJykKICAgIGFwKCdSRU0gU0tJTEwtY29yZS5tZCBpcyBhIGJ1
>> "!B64TMP!" echo aWxkLXRpbWUgdmFyaWFudCAtIG5ldmVyIHBhcnQgb2YgYW4gaW5zdGFsbGVkIHNraWxsLicpCiAg
>> "!B64TMP!" echo ICBhcCgnaWYgZXhpc3QgIiFUQVJHRVQhXFxsb2NhbC13ZWItc2VhcmNoXFxTS0lMTC1jb3JlLm1k
>> "!B64TMP!" echo IiBkZWwgL1EgIiFUQVJHRVQhXFxsb2NhbC13ZWItc2VhcmNoXFxTS0lMTC1jb3JlLm1kIiA+bnVs
>> "!B64TMP!" echo IDI+JjEnKQogICAgYXAoJycpCiAgICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAgICMgIEluc3RhbGwgdGhlIGJ1
>> "!B64TMP!" echo bmRsZWQgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCBza2lsbCBpbnRvIHRoZSB1c2VyJ3Mgc2tpbGxz
>> "!B64TMP!" echo CiAgICAjICBkaXJlY3RvcnkgKGFkZC9vdmVycmlkZSksIGFuZCByZWNvcmQgdGhlIGluc3RhbGwg
>> "!B64TMP!" echo cGF0aCBoaW50LgogICAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgICBhcCgnZWNobyBJbnN0YWxsaW5nIHRoZSBs
>> "!B64TMP!" echo b2NhbC13ZWItc2VhcmNoIGFnZW50IHNraWxsLi4uJykKICAgIGFwKCdzZXQgIlNLSUxMX0RJUj0l
>> "!B64TMP!" echo VVNFUlBST0ZJTEUlXFwuYWdlbnRzXFxza2lsbHNcXGxvY2FsLXdlYi1zZWFyY2giJykKICAgIGFw
>> "!B64TMP!" echo KCdpZiBleGlzdCAiIVNLSUxMX0RJUiEiIHJkIC9zIC9xICIhU0tJTExfRElSISInKQogICAgYXAo
>> "!B64TMP!" echo J2lmIG5vdCBleGlzdCAiJVVTRVJQUk9GSUxFJVxcLmFnZW50c1xcc2tpbGxzIiBta2RpciAiJVVT
>> "!B64TMP!" echo RVJQUk9GSUxFJVxcLmFnZW50c1xcc2tpbGxzIicpCiAgICBhcCgneGNvcHkgL0UgL0kgL1kgL1Eg
>> "!B64TMP!" echo IiFUQVJHRVQhXFxsb2NhbC13ZWItc2VhcmNoIiAiIVNLSUxMX0RJUiEiID5udWwnKQogICAgYXAo
>> "!B64TMP!" echo J2lmIGVycm9ybGV2ZWwgMSAoJykKICAgIGFwKCcgIGVjaG8gICBbV0FSTklOR10gQ291bGQgbm90
>> "!B64TMP!" echo IGNvcHkgdGhlIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwgdG8gIVNLSUxMX0RJUiEuJykKICAgIGFw
>> "!B64TMP!" echo KCcpIGVsc2UgKCcpCiAgICBhcCgnICA+ICIhVEFSR0VUIVxcbG9jYWwtd2ViLXNlYXJjaFxcaW5z
>> "!B64TMP!" echo dGFsbC1kaXIudHh0IiBlY2hvICFUQVJHRVQhJykKICAgIGFwKCcgID4gIiFTS0lMTF9ESVIhXFxp
>> "!B64TMP!" echo bnN0YWxsLWRpci50eHQiIGVjaG8gIVRBUkdFVCEnKQogICAgYXAoJyAgZWNobyAgIEFnZW50IHNr
>> "!B64TMP!" echo aWxsIGluc3RhbGxlZDogIVNLSUxMX0RJUiEnKQogICAgYXAoJyknKQogICAgYXAoJycpCiAgICAj
>> "!B64TMP!" echo IFdhaXQgZm9yIHRoZSBlbmdpbmUgaWYgd2UgbGF1bmNoZWQgRG9ja2VyIERlc2t0b3AgZWFybGll
>> "!B64TMP!" echo ciAodGhlIHByb21wdHMKICAgICMgYWJvdmUgcmFuIHdoaWxlIGl0IHdhcyBib290aW5nIGluIHRo
>> "!B64TMP!" echo ZSBiYWNrZ3JvdW5kKS4KICAgIGFwKCdSRU0gSG93IGxvbmcgdG8gd2FpdCBmb3IgYSBqdXN0LWxh
>> "!B64TMP!" echo dW5jaGVkIERvY2tlciBlbmdpbmUgdG8gY29tZSBvbmxpbmUgKHNlY29uZHMpLicpCiAgICBhcCgn
>> "!B64TMP!" echo c2V0ICJERF9USU1FT1VUPTMwMCInKQogICAgYXAoJ2lmIGRlZmluZWQgTE9DQUxfU0VBUkNIX0RP
>> "!B64TMP!" echo Q0tFUl9USU1FT1VUIHNldCAiRERfVElNRU9VVD0hTE9DQUxfU0VBUkNIX0RPQ0tFUl9USU1FT1VU
>> "!B64TMP!" echo ISInKQogICAgYXAoJ2lmIG5vdCBkZWZpbmVkIEREX0xBVU5DSEVEIGdvdG8gZG9ja2VyX2VuZ2lu
>> "!B64TMP!" echo ZV9yZWFkeScpCiAgICBhcCgnZWNobyBXYWl0aW5nIGZvciB0aGUgRG9ja2VyIGVuZ2luZSB0byBj
>> "!B64TMP!" echo b21lIG9ubGluZSAtIHVwIHRvICFERF9USU1FT1VUISBzZWNvbmRzLi4uJykKICAgIGFwKCdzZXQg
>> "!B64TMP!" echo L2EgRERfV0FJVD0wJykKICAgIGFwKCc6ZG9ja2VyX3dhaXQnKQogICAgYXAoJ3RpbWVvdXQgL3Qg
>> "!B64TMP!" echo NSAvbm9icmVhayA+bnVsIDI+JjEnKQogICAgYXAoJ2lmIGVycm9ybGV2ZWwgMSBwaW5nIC1uIDYg
>> "!B64TMP!" echo MTI3LjAuMC4xID5udWwgMj4mMScpCiAgICBhcCgnc2V0IC9hIEREX1dBSVQrPTUnKQogICAgYXAo
>> "!B64TMP!" echo J2RvY2tlciBpbmZvID5udWwgMj4mMScpCiAgICBhcCgnaWYgbm90IGVycm9ybGV2ZWwgMSBnb3Rv
>> "!B64TMP!" echo IGRvY2tlcl9lbmdpbmVfcmVhZHknKQogICAgYXAoJ2lmICFERF9XQUlUISBnZXEgIUREX1RJTUVP
>> "!B64TMP!" echo VVQhICgnKQogICAgYXAoJyAgZWNobyBbRVJST1JdIFRoZSBEb2NrZXIgZW5naW5lIGRpZCBub3Qg
>> "!B64TMP!" echo Y29tZSBvbmxpbmUgd2l0aGluICFERF9USU1FT1VUISBzZWNvbmRzLicpCiAgICBhcCgnICBlY2hv
>> "!B64TMP!" echo ICAgQ2hlY2sgRG9ja2VyIERlc2t0b3AgZm9yIGVycm9ycywgd2FpdCB1bnRpbCBpdCBzYXlzICJy
>> "!B64TMP!" echo dW5uaW5nIiwnKQogICAgYXAoJyAgZWNobyAgIHRoZW4gcmUtcnVuIHRoaXMgaW5zdGFsbGVyLicp
>> "!B64TMP!" echo CiAgICBhcCgnICBwYXVzZSAmIGV4aXQgL2IgMScpCiAgICBhcCgnKScpCiAgICBhcCgnc2V0IC9h
>> "!B64TMP!" echo ICJERF9NT0Q9RERfV0FJVCAlJSAxNSInKQogICAgYXAoJ2lmICFERF9NT0QhIGVxdSAwIGVjaG8g
>> "!B64TMP!" echo ICAgIC4uLiBzdGlsbCB3YWl0aW5nICFERF9XQUlUIXMnKQogICAgYXAoJ2dvdG8gZG9ja2VyX3dh
>> "!B64TMP!" echo aXQnKQogICAgYXAoJzpkb2NrZXJfZW5naW5lX3JlYWR5JykKICAgIGFwKCdpZiBkZWZpbmVkIERE
>> "!B64TMP!" echo X0xBVU5DSEVEIGVjaG8gW09LXSBEb2NrZXIgZW5naW5lIGlzIG9ubGluZSBhZnRlciAhRERfV0FJ
>> "!B64TMP!" echo VCFzLicpCiAgICBhcCgnJykKICAgICMgUHVsbCArIHVwCiAgICBhcCgnZWNoby4nKQogICAgYXAo
>> "!B64TMP!" echo J2VjaG8gUHVsbGluZyBEb2NrZXIgaW1hZ2VzIChmaXJzdCBydW4gZG93bmxvYWRzIH4zLTQgR0Is
>> "!B64TMP!" echo IHBsZWFzZSBiZSBwYXRpZW50KS4uLicpCiAgICBhcCgncHVzaGQgIiFUQVJHRVQhIicpCiAgICBh
>> "!B64TMP!" echo cCgnZG9ja2VyIGNvbXBvc2UgcHVsbCcpCiAgICBhcCgnaWYgIWVycm9ybGV2ZWwhIG5lcSAwICgg
>> "!B64TMP!" echo ZWNobyAgIFtXQVJOSU5HXSBkb2NrZXIgY29tcG9zZSBwdWxsIHJlcG9ydGVkIGVycm9ycy4gVHJ5
>> "!B64TMP!" echo aW5nIHRvIHN0YXJ0IGFueXdheS4uLiApJykKICAgIGFwKCdlY2hvIFN0YXJ0aW5nIHNlcnZpY2Vz
>> "!B64TMP!" echo Li4uJykKICAgIGFwKCdkb2NrZXIgY29tcG9zZSB1cCAtZCcpCiAgICBhcCgnc2V0ICJVUF9SQz0h
>> "!B64TMP!" echo ZXJyb3JsZXZlbCEiJykKICAgIGFwKCdwb3BkJykKICAgIGFwKCdpZiAhVVBfUkMhIG5lcSAwICgn
>> "!B64TMP!" echo KQogICAgYXAoJyAgZWNoby4nKQogICAgYXAoJyAgZWNobyBbRVJST1JdIGRvY2tlciBjb21wb3Nl
>> "!B64TMP!" echo IHVwIGZhaWxlZC4gU2VlIG1lc3NhZ2VzIGFib3ZlLicpCiAgICBhcCgnICBlY2hvICAgQ29tbW9u
>> "!B64TMP!" echo IGZpeGVzOicpCiAgICBhcCgnICBlY2hvICAgICAtIE1ha2Ugc3VyZSBEb2NrZXIgRGVza3RvcCBp
>> "!B64TMP!" echo cyBydW5uaW5nLicpCiAgICBhcCgnICBlY2hvICAgICAtIE1ha2Ugc3VyZSBwb3J0cyAhU0VBUlhO
>> "!B64TMP!" echo R19QT1JUISBhbmQgIUZJUkVDUkFXTF9QT1JUISBhcmUgbm90IGluIHVzZS4nKQogICAgYXAoJyAg
>> "!B64TMP!" echo ZWNobyAgICAgLSBSZS1ydW4gdGhpcyBpbnN0YWxsZXIgb3IgcnVuIFVwZGF0ZS5iYXQgYWZ0ZXIg
>> "!B64TMP!" echo Zml4aW5nLicpCiAgICBhcCgnICBlY2hvLicpCiAgICBhcCgnICBwYXVzZSAmIGV4aXQgL2IgMScp
>> "!B64TMP!" echo CiAgICBhcCgnKScpCiAgICBhcCgnJykKICAgICMgRG9uZQogICAgYXAoJ2VjaG8uJykKICAgIGFw
>> "!B64TMP!" echo KCdlY2hvID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PScpCiAgICBhcCgnZWNobyAgIEluc3RhbGxhdGlvbiBjb21wbGV0ZSEnKQogICAg
>> "!B64TMP!" echo YXAoJ2VjaG8uJykKICAgIGFwKCdlY2hvICAgU2VhclhORyAgKHNlYXJjaCArIEpTT04gQVBJKTog
>> "!B64TMP!" echo IGh0dHA6Ly9sb2NhbGhvc3Q6IVNFQVJYTkdfUE9SVCEnKQogICAgYXAoJ2VjaG8gICBGaXJlY3Jh
>> "!B64TMP!" echo d2wgKHNjcmFwZS9jcmF3bCBBUEkpOiBodHRwOi8vbG9jYWxob3N0OiFGSVJFQ1JBV0xfUE9SVCEn
>> "!B64TMP!" echo KQogICAgYXAoJ2VjaG8gICBsb2NhbC13ZWItc2VhcmNoIHNraWxsOiAgICAgICAgICAgICAgJVVT
>> "!B64TMP!" echo RVJQUk9GSUxFJVxcLmFnZW50c1xcc2tpbGxzXFxsb2NhbC13ZWItc2VhcmNoJykKICAgIGFwKCdl
>> "!B64TMP!" echo Y2hvLicpCiAgICBhcCgnZWNobyAgIElmIHlvdXIgYWdlbnQgd2FzIGFscmVhZHkgcnVubmluZywg
>> "!B64TMP!" echo cmVzdGFydCBpdCBzbyBpdCBwaWNrcyB1cCcpCiAgICBhcCgnZWNobyAgIHRoZSBuZXcgc2tpbGwu
>> "!B64TMP!" echo JykKICAgIGFwKCdlY2hvLicpCiAgICBhcCgnZWNobyAgIE1hbmFnZSB0aGUgc3RhY2sgd2l0aCB0
>> "!B64TMP!" echo aGUgLmJhdCBmaWxlcyBpbjonKQogICAgYXAoJ2VjaG8gICAgICFUQVJHRVQhJykKICAgIGFwKCdl
>> "!B64TMP!" echo Y2hvICAgICAgIFJ1bi5iYXQgICBTdG9wLmJhdCAgIFVwZGF0ZS5iYXQgICBVbmluc3RhbGwuYmF0
>> "!B64TMP!" echo JykKICAgIGFwKCdlY2hvLicpCiAgICBhcCgnZWNobyAgIFNlZSBSRUFETUUubWQgZm9yIGhvdyB0
>> "!B64TMP!" echo byBjb25uZWN0IHRoaXMgdG8geW91ciBBSSBtb2RlbHMnKQogICAgYXAoJ2VjaG8gICAobG9jYWwt
>> "!B64TMP!" echo d2ViLXNlYXJjaCBza2lsbCwgTE0gU3R1ZGlvLCBNQ1Agc2VydmVyLCBkaXJlY3QgcHJvbXB0aW5n
>> "!B64TMP!" echo LCBldGMuKS4nKQogICAgYXAoJ2VjaG8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCdlY2hvLicpCiAgICBhcCgncGF1
>> "!B64TMP!" echo c2UnKQogICAgYXAoJ2V4aXQgL2IgMCcpCiAgICBhcCgnJykKICAgICMgU3Vicm91dGluZXMKICAg
>> "!B64TMP!" echo IGFwKCdSRU0gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCdSRU0gIFN1YnJvdXRpbmVzJykK
>> "!B64TMP!" echo ICAgIGFwKCdSRU0gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCcnKQogICAgYXAoJzp2YWxp
>> "!B64TMP!" echo ZGF0ZV9wb3J0JykKICAgIGFwKCdlY2hvICV+MXwgZmluZHN0ciAvciAvYzoiXlswLTldWzAtOV0q
>> "!B64TMP!" echo JCIgPm51bCcpCiAgICBhcCgnaWYgZXJyb3JsZXZlbCAxIGV4aXQgL2IgMScpCiAgICBhcCgnaWYg
>> "!B64TMP!" echo JX4xIGxzcyAxIGV4aXQgL2IgMScpCiAgICBhcCgnaWYgJX4xIGd0ciA2NTUzNSBleGl0IC9iIDEn
>> "!B64TMP!" echo KQogICAgYXAoJ2V4aXQgL2IgMCcpCiAgICBhcCgnJykKICAgIGFwKCc6Z2Vua2V5JykKICAgIGFw
>> "!B64TMP!" echo KCdzZXQgIktGSUxFPSVURU1QJVxcbG9jYWxfc2VhcmNoX2tleS50bXAiJykKICAgIGFwKCdwb3dl
>> "!B64TMP!" echo cnNoZWxsIC1Ob1Byb2ZpbGUgLUNvbW1hbmQgIiRybmc9W1NlY3VyaXR5LkNyeXB0b2dyYXBoeS5S
>> "!B64TMP!" echo YW5kb21OdW1iZXJHZW5lcmF0b3JdOjpDcmVhdGUoKTsgJHI9TmV3LU9iamVjdCBieXRlW10gMzI7
>> "!B64TMP!" echo ICRybmcuR2V0Qnl0ZXMoJHIpOyAtam9pbiAoJHIgfCBGb3JFYWNoLU9iamVjdCB7ICRfLlRvU3Ry
>> "!B64TMP!" echo aW5nKFwneDJcJykgfSkiID4gIiVLRklMRSUiJykKICAgIGFwKCdzZXQgL3AgIiV+MT0iIDwgIiVL
>> "!B64TMP!" echo RklMRSUiJykKICAgIGFwKCdkZWwgIiVLRklMRSUiID5udWwgMj4mMScpCiAgICBhcCgnZXhpdCAv
>> "!B64TMP!" echo YiAwJykKICAgIGFwKCcnKQogICAgYXAoJzpkZWNvZGVfYjY0JykKICAgIGFwKCdSRU0gICUxID0g
>> "!B64TMP!" echo cGF0aCB0byBhIC5iNjQgdGV4dCBmaWxlLCAlMiA9IG91dHB1dCBiaW5hcnkgcGF0aCAobWF5IG5v
>> "!B64TMP!" echo dCBleGlzdCB5ZXQpJykKICAgIGFwKCdSRU0gIFBhc3MgcGF0aHMgdmlhIFBTIHZhcmlhYmxlcyB0
>> "!B64TMP!" echo byBzdXJ2aXZlIHNwYWNlcyAvIHF1b3RlcyBpbiBUQVJHRVQuJykKICAgIGFwKCdwb3dlcnNoZWxs
>> "!B64TMP!" echo IC1Ob1Byb2ZpbGUgLUNvbW1hbmQgIiRpbj0kZW52OkxTX0I2NF9JTjsgJG91dD0kZW52OkxTX0I2
>> "!B64TMP!" echo NF9PVVQ7IFtJTy5GaWxlXTo6V3JpdGVBbGxCeXRlcygkb3V0LCBbQ29udmVydF06OkZyb21CYXNl
>> "!B64TMP!" echo NjRTdHJpbmcoKChHZXQtQ29udGVudCAtUmF3ICRpbikgLXJlcGxhY2UgXCdcXHNcJyxcJ1wnKSkp
>> "!B64TMP!" echo IicpCiAgICBhcCgnZXhpdCAvYiAwJykKCiAgICByZXR1cm4gIlxyXG4iLmpvaW4ob3V0KSArICJc
>> "!B64TMP!" echo clxuIgoKCiMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KIyAgTGludXggLyBtYWNPUyBpbnN0YWxsZXIg
>> "!B64TMP!" echo KC5zaCkKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PQoKZGVmIGdlbl9zaCgpOgogICAgb3V0ID0gW10K
>> "!B64TMP!" echo ICAgIGFwID0gb3V0LmFwcGVuZAoKICAgIGFwKCcjIS91c3IvYmluL2VudiBiYXNoJykKICAgIGFw
>> "!B64TMP!" echo KCcjID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCcjICBMb2NhbCBTZWFyY2ggSW5zdGFs
>> "!B64TMP!" echo bGVyICAoRmlyZWNyYXdsICsgU2VhclhORyArIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwpJykKICAg
>> "!B64TMP!" echo IGFwKCcjICAgICAgICAgICAgICAgICAgICAgICAgLSAgTGludXggJiBtYWNPUycpCiAgICBhcCgn
>> "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBhcCgnIyAgU2VsZi1jb250YWluZWQ6IGV2ZXJ5
>> "!B64TMP!" echo IGZpbGUgdGhlIGluc3RhbGxlciBuZWVkcyBpcyBlbWJlZGRlZCBiZWxvdyBhcyBhJykKICAgIGFw
>> "!B64TMP!" echo KCcjICBxdW90ZWQgaGVyZWRvYy4gSWYgYSBzb3VyY2UgZmlsZSBpcyBtaXNzaW5nIGZyb20gdGhp
>> "!B64TMP!" echo cyBzY3JpcHRcJ3MgZm9sZGVyJykKICAgIGFwKCcjICAoZS5nLiB5b3Ugb25seSBkb3dubG9hZGVk
>> "!B64TMP!" echo IHRoaXMgb25lIC5zaCksIHRoZSBlbWJlZGRlZCBjb3B5IGlzIHVzZWQuJykKICAgIGFwKCcjICBB
>> "!B64TMP!" echo ZnRlciBpbnN0YWxsaW5nIHRoZSBzdGFjayBpdCBhbHNvIGNvcGllcyB0aGUgYnVuZGxlZCBsb2Nh
>> "!B64TMP!" echo bC13ZWItc2VhcmNoIGFnZW50JykKICAgIGFwKCcjICBza2lsbCBpbnRvIH4vLmFnZW50cy9za2ls
>> "!B64TMP!" echo bHMvbG9jYWwtd2ViLXNlYXJjaC4nKQogICAgYXAoJyMgIFRoZSBpbnN0YWxsZXIgYXNrcyBhIHkv
>> "!B64TMP!" echo TiAiQWRkIGEgRmlyZWNyYXdsIGFjY291bnQ/IiBxdWVzdGlvbiAoZGVmYXVsdCBOKTonKQogICAg
>> "!B64TMP!" echo YXAoJyMgIHdpdGhvdXQgYW4gYWNjb3VudCBvbmx5IHRoZSBmcmVlIGxvY2FsIHNraWxsIHRvb2xz
>> "!B64TMP!" echo IGFyZSBpbnN0YWxsZWQgKHRoZScpCiAgICBhcCgnIyAgMTkgYWNjb3VudC1nYXRlZCBzY3JpcHRz
>> "!B64TMP!" echo IGFyZSBza2lwcGVkIGFuZCBhIGNvcmUtb25seSBTS0lMTC5tZCBpcyB1c2VkKTsnKQogICAgYXAo
>> "!B64TMP!" echo JyMgIHdpdGggb25lIHRoZSBjcmVkZW50aWFscyBhcmUgd3JpdHRlbiB0byAuZW52IGFuZCBhbGwg
>> "!B64TMP!" echo MjUgdG9vbHMgaW5zdGFsbC4nKQogICAgYXAoJyMgIElmIHRoZSBEb2NrZXIgZW5naW5lIGlzIG5v
>> "!B64TMP!" echo dCBydW5uaW5nLCB0aGUgaW5zdGFsbGVyIHRyaWVzIHRvIHN0YXJ0IGl0JykKICAgIGFwKCcjICBh
>> "!B64TMP!" echo dXRvbWF0aWNhbGx5IChEb2NrZXIgRGVza3RvcCBvbiBtYWNPUywgc3lzdGVtY3RsL3NlcnZpY2Ug
>> "!B64TMP!" echo b24gTGludXgpJykKICAgIGFwKCcjICBhbmQgd2FpdHMgZm9yIGl0IGJlZm9yZSBwdWxsaW5nIGlt
>> "!B64TMP!" echo YWdlcy4nKQogICAgYXAoJyMgPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJycpCiAgICBh
>> "!B64TMP!" echo cCgnc2V0IC11JykKICAgIGFwKCcnKQogICAgYXAoJ0JPTEQ9IlxcMDMzWzFtIjsgRElNPSJcXDAz
>> "!B64TMP!" echo M1sybSI7IEdSRUVOPSJcXDAzM1szMm0iOyBZRUxMT1c9IlxcMDMzWzMzbSI7IFJFRD0iXFwwMzNb
>> "!B64TMP!" echo MzFtIjsgQ1lBTj0iXFwwMzNbMzZtIjsgUkVTRVQ9IlxcMDMzWzBtIicpCiAgICBhcCgnc2F5KCkg
>> "!B64TMP!" echo IHsgcHJpbnRmICIlYlxcbiIgIiQxIjsgfScpCiAgICBhcCgnZXJyKCkgIHsgcHJpbnRmICIlYltF
>> "!B64TMP!" echo UlJPUl0lYiAlc1xcbiIgIiRSRUQiICIkUkVTRVQiICIkMSIgPiYyOyB9JykKICAgIGFwKCdvaygp
>> "!B64TMP!" echo ICAgeyBwcmludGYgIiViW09LXSViICVzXFxuIiAiJEdSRUVOIiAiJFJFU0VUIiAiJDEiOyB9JykK
>> "!B64TMP!" echo ICAgIGFwKCdoZHIoKSAgeyBwcmludGYgIlxcbiViLS0tICVzIC0tLSViXFxuIiAiJENZQU4iICIk
>> "!B64TMP!" echo MSIgIiRSRVNFVCI7IH0nKQogICAgYXAoJ2xvd2VyKCkgeyBwcmludGYgXCclc1wnICIkMSIgfCB0
>> "!B64TMP!" echo ciBcJ1s6dXBwZXI6XVwnIFwnWzpsb3dlcjpdXCc7IH0gICMgYmFzaC0zLjIgKG1hY09TKSBzYWZl
>> "!B64TMP!" echo JykKICAgIGFwKCcnKQogICAgYXAoJ2NhdCA8PFwnQkFOTkVSXCcnKQogICAgYXAoJz09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAg
>> "!B64TMP!" echo ICBhcCgnICBMb2NhbCBTZWFyY2ggSW5zdGFsbGVyICAoRmlyZWNyYXdsICsgU2VhclhORyArIGxv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2gpJykKICAgIGFwKCcgIEEgbG9jYWwgd2ViLWJyb3dzaW5nIHN5c3RlbSBm
>> "!B64TMP!" echo b3IgQUkgbW9kZWxzLicpCiAgICBhcCgnPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCdCQU5ORVInKQogICAgYXAoJycp
>> "!B64TMP!" echo CiAgICAjIERvY2tlciBjaGVjawogICAgYXAoJ2lmICEgY29tbWFuZCAtdiBkb2NrZXIgPi9kZXYv
>> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuJykKICAgIGFwKCcgIGVyciAiRG9ja2VyIHdhcyBub3QgZm91bmQgb24g
>> "!B64TMP!" echo eW91ciBQQVRILiInKQogICAgYXAoJyAgc2F5ICIiJykKICAgIGFwKCcgIHNheSAiSW5zdGFsbCBE
>> "!B64TMP!" echo b2NrZXIgRW5naW5lIChMaW51eCkgb3IgRG9ja2VyIERlc2t0b3AgKG1hY09TKToiJykKICAgIGFw
>> "!B64TMP!" echo KCcgIHNheSAiICBMaW51eDogICBodHRwczovL2RvY3MuZG9ja2VyLmNvbS9lbmdpbmUvaW5zdGFs
>> "!B64TMP!" echo bC8iJykKICAgIGFwKCcgIHNheSAiICBtYWNPUzogICBodHRwczovL3d3dy5kb2NrZXIuY29tL3By
>> "!B64TMP!" echo b2R1Y3RzL2RvY2tlci1kZXNrdG9wLyInKQogICAgYXAoJyAgc2F5ICJUaGVuIHJlLXJ1biB0aGlz
>> "!B64TMP!" echo IGluc3RhbGxlci4iJykKICAgIGFwKCcgIGV4aXQgMScpCiAgICBhcCgnZmknKQogICAgIyBEb2Nr
>> "!B64TMP!" echo ZXIgZW5naW5lIGNoZWNrIC0gdHJ5IHRvIFNUQVJUIGl0IGF1dG9tYXRpY2FsbHkgd2hlbiBpdCBp
>> "!B64TMP!" echo cyBkb3duLgogICAgYXAoJyMgSG93IGxvbmcgdG8gd2FpdCBmb3IgYSBqdXN0LWxhdW5jaGVkIERv
>> "!B64TMP!" echo Y2tlciBlbmdpbmUgKHNlY29uZHMpLicpCiAgICBhcCgnRE9DS0VSX1dBSVRfVElNRU9VVD0iJHtM
>> "!B64TMP!" echo T0NBTF9TRUFSQ0hfRE9DS0VSX1RJTUVPVVQ6LTMwMH0iJykKICAgIGFwKCdFTkdJTkVfTEFVTkNI
>> "!B64TMP!" echo RUQ9MCcpCiAgICBhcCgnaWYgISBkb2NrZXIgaW5mbyA+L2Rldi9udWxsIDI+JjE7IHRoZW4nKQog
>> "!B64TMP!" echo ICAgYXAoJyAgc2F5ICIgICR7WUVMTE9XfVshXSR7UkVTRVR9IFRoZSBEb2NrZXIgZW5naW5lIGlz
>> "!B64TMP!" echo IG5vdCBydW5uaW5nIC0gdHJ5aW5nIHRvIHN0YXJ0IGl0Li4uIicpCiAgICBhcCgnICBFTkdJTkVf
>> "!B64TMP!" echo U1RBUlRFRD0wJykKICAgIGFwKCcgIGlmIFsgIiQodW5hbWUpIiA9ICJEYXJ3aW4iIF07IHRoZW4n
>> "!B64TMP!" echo KQogICAgYXAoJyAgICAjIG1hY09TOiBsYXVuY2ggRG9ja2VyIERlc2t0b3AgaWYgaXQgaXMgaW5z
>> "!B64TMP!" echo dGFsbGVkJykKICAgIGFwKCcgICAgaWYgY29tbWFuZCAtdiBvcGVuID4vZGV2L251bGwgMj4mMSBc
>> "!B64TMP!" echo XCcpCiAgICBhcCgnICAgICAgICYmIHsgWyAtZCAiL0FwcGxpY2F0aW9ucy9Eb2NrZXIuYXBwIiBd
>> "!B64TMP!" echo IHx8IFsgLWQgIiRIT01FL0FwcGxpY2F0aW9ucy9Eb2NrZXIuYXBwIiBdOyB9OyB0aGVuJykKICAg
>> "!B64TMP!" echo IGFwKCcgICAgICBvcGVuIC1hIERvY2tlciA+L2Rldi9udWxsIDI+JjEgJiYgRU5HSU5FX1NUQVJU
>> "!B64TMP!" echo RUQ9MScpCiAgICBhcCgnICAgIGZpJykKICAgIGFwKCcgIGVsc2UnKQogICAgYXAoJyAgICAjIExp
>> "!B64TMP!" echo bnV4OiBzeXN0ZW1kIHVuaXRzIChEb2NrZXIgRGVza3RvcCB1c2VzIGRvY2tlci1kZXNrdG9wLCB0
>> "!B64TMP!" echo aGUnKQogICAgYXAoJyAgICAjIGNsYXNzaWMgZW5naW5lIHVzZXMgZG9ja2VyKSwgdGhlbiBzZXJ2
>> "!B64TMP!" echo aWNlKDEpLiBOb24taW50ZXJhY3RpdmUnKQogICAgYXAoJyAgICAjIHN1ZG8gb25seSAtIGFuIGlu
>> "!B64TMP!" echo c3RhbGxlciBuZXZlciBwcm9tcHRzIGZvciBhIHBhc3N3b3JkLicpCiAgICBhcCgnICAgIGlmIGNv
>> "!B64TMP!" echo bW1hbmQgLXYgc3lzdGVtY3RsID4vZGV2L251bGwgMj4mMTsgdGhlbicpCiAgICBhcCgnICAgICAg
>> "!B64TMP!" echo Zm9yIHVuaXQgaW4gZG9ja2VyLWRlc2t0b3AgZG9ja2VyOyBkbycpCiAgICBhcCgnICAgICAgICBp
>> "!B64TMP!" echo ZiBzeXN0ZW1jdGwgc3RhcnQgIiR1bml0IiA+L2Rldi9udWxsIDI+JjE7IHRoZW4gRU5HSU5FX1NU
>> "!B64TMP!" echo QVJURUQ9MTsgYnJlYWs7IGZpJykKICAgIGFwKCcgICAgICAgIGlmIGNvbW1hbmQgLXYgc3VkbyA+
>> "!B64TMP!" echo L2Rldi9udWxsIDI+JjEgXFwnKQogICAgYXAoJyAgICAgICAgICAgJiYgc3VkbyAtbiBzeXN0ZW1j
>> "!B64TMP!" echo dGwgc3RhcnQgIiR1bml0IiA+L2Rldi9udWxsIDI+JjE7IHRoZW4nKQogICAgYXAoJyAgICAgICAg
>> "!B64TMP!" echo ICBFTkdJTkVfU1RBUlRFRD0xOyBicmVhaycpCiAgICBhcCgnICAgICAgICBmaScpCiAgICBhcCgn
>> "!B64TMP!" echo ICAgICAgZG9uZScpCiAgICBhcCgnICAgIGZpJykKICAgIGFwKCcgICAgaWYgWyAiJEVOR0lORV9T
>> "!B64TMP!" echo VEFSVEVEIiAtbmUgMSBdICYmIGNvbW1hbmQgLXYgc2VydmljZSA+L2Rldi9udWxsIDI+JjE7IHRo
>> "!B64TMP!" echo ZW4nKQogICAgYXAoJyAgICAgIGlmIHNlcnZpY2UgZG9ja2VyIHN0YXJ0ID4vZGV2L251bGwgMj4m
>> "!B64TMP!" echo MTsgdGhlbiBFTkdJTkVfU1RBUlRFRD0xJykKICAgIGFwKCcgICAgICBlbGlmIGNvbW1hbmQgLXYg
>> "!B64TMP!" echo c3VkbyA+L2Rldi9udWxsIDI+JjEgXFwnKQogICAgYXAoJyAgICAgICAgICYmIHN1ZG8gLW4gc2Vy
>> "!B64TMP!" echo dmljZSBkb2NrZXIgc3RhcnQgPi9kZXYvbnVsbCAyPiYxOyB0aGVuJykKICAgIGFwKCcgICAgICAg
>> "!B64TMP!" echo IEVOR0lORV9TVEFSVEVEPTEnKQogICAgYXAoJyAgICAgIGZpJykKICAgIGFwKCcgICAgZmknKQog
>> "!B64TMP!" echo ICAgYXAoJyAgZmknKQogICAgYXAoJyAgaWYgWyAiJEVOR0lORV9TVEFSVEVEIiAtbmUgMSBdOyB0
>> "!B64TMP!" echo aGVuJykKICAgIGFwKCcgICAgZXJyICJDb3VsZCBub3Qgc3RhcnQgdGhlIERvY2tlciBlbmdpbmUg
>> "!B64TMP!" echo YXV0b21hdGljYWxseS4iJykKICAgIGFwKCcgICAgc2F5ICIiJykKICAgIGFwKCcgICAgc2F5ICJT
>> "!B64TMP!" echo dGFydCBpdCBtYW51YWxseSwgdGhlbiByZS1ydW4gdGhpcyBpbnN0YWxsZXI6IicpCiAgICBhcCgn
>> "!B64TMP!" echo ICAgIHNheSAiICBMaW51eDogIHN1ZG8gc3lzdGVtY3RsIHN0YXJ0IGRvY2tlciAgICAob3IgbGF1
>> "!B64TMP!" echo bmNoIERvY2tlciBEZXNrdG9wKSInKQogICAgYXAoJyAgICBzYXkgIiAgICAgICAgICBwZXJtaXNz
>> "!B64TMP!" echo aW9uIGRlbmllZCBmcm9tIGRvY2tlcj8gYWRkIHlvdXJzZWxmIHRvIHRoZSBkb2NrZXIiJykKICAg
>> "!B64TMP!" echo IGFwKCcgICAgc2F5ICIgICAgICAgICAgZ3JvdXA6ICBzdWRvIHVzZXJtb2QgLWFHIGRvY2tlciAk
>> "!B64TMP!" echo VVNFUiAgKGxvZyBvdXQgYW5kIGJhY2sgaW4pIicpCiAgICBhcCgnICAgIHNheSAiICBtYWNPUzog
>> "!B64TMP!" echo IG9wZW4gLWEgRG9ja2VyIicpCiAgICBhcCgnICAgIGV4aXQgMScpCiAgICBhcCgnICBmaScpCiAg
>> "!B64TMP!" echo ICBhcCgnICBFTkdJTkVfTEFVTkNIRUQ9MScpCiAgICBhcCgnICBzYXkgIiAgTGF1bmNoZWQgRG9j
>> "!B64TMP!" echo a2VyIGluIHRoZSBiYWNrZ3JvdW5kLiBBbnN3ZXIgdGhlIG5leHQgcXVlc3Rpb25zIHdoaWxlIicp
>> "!B64TMP!" echo CiAgICBhcCgnICBzYXkgIiAgaXQgYm9vdHMgLSB0aGUgaW5zdGFsbGVyIHdhaXRzIGZvciB0aGUg
>> "!B64TMP!" echo ZW5naW5lIGJlZm9yZSBwdWxsaW5nIGltYWdlcy4iJykKICAgIGFwKCdmaScpCiAgICBhcCgnaWYg
>> "!B64TMP!" echo ZG9ja2VyIGNvbXBvc2UgdmVyc2lvbiA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRvY2tlciBj
>> "!B64TMP!" echo b21wb3NlIicpCiAgICBhcCgnZWxpZiBjb21tYW5kIC12IGRvY2tlci1jb21wb3NlID4vZGV2L251
>> "!B64TMP!" echo bGwgMj4mMTsgdGhlbiBEQz0iZG9ja2VyLWNvbXBvc2UiJykKICAgIGFwKCdlbHNlIGVyciAiRG9j
>> "!B64TMP!" echo a2VyIENvbXBvc2Ugd2FzIG5vdCBmb3VuZC4gSW5zdGFsbCB0aGUgXCdkb2NrZXIgY29tcG9zZVwn
>> "!B64TMP!" echo IHBsdWdpbiAodjIpLiI7IGV4aXQgMTsgZmknKQogICAgYXAoJ29rICJEb2NrZXIgYW5kIERvY2tl
>> "!B64TMP!" echo ciBDb21wb3NlIGFyZSBhdmFpbGFibGUgKCREQykuIicpCiAgICBhcCgnJykKICAgICMgU291cmNl
>> "!B64TMP!" echo IGZvbGRlcgogICAgYXAoJ1NSQz0iJChjZCAiJChkaXJuYW1lICIkMCIpIiAmJiBwd2QpIicpCiAg
>> "!B64TMP!" echo ICBhcCgnJykKICAgICMgUHJvbXB0cwogICAgYXAoJ0RFRkFVTFRfVEFSR0VUPSIkSE9NRS9sb2Nh
>> "!B64TMP!" echo bC1zZWFyY2giJykKICAgIGFwKCdoZHIgIlN0ZXAgMSBvZiA1OiBJbnN0YWxsIGxvY2F0aW9uIicp
>> "!B64TMP!" echo CiAgICBhcCgnc2F5ICIgIERlZmF1bHQ6ICRERUZBVUxUX1RBUkdFVCInKQogICAgYXAoJ3ByaW50
>> "!B64TMP!" echo ZiAiICBUYXJnZXQgZm9sZGVyIFtwcmVzcyBFbnRlciBmb3IgZGVmYXVsdF06ICInKQogICAgYXAo
>> "!B64TMP!" echo J3JlYWQgLXIgVEFSR0VUJykKICAgIGFwKCdbIC16ICIkVEFSR0VUIiBdICYmIFRBUkdFVD0iJERF
>> "!B64TMP!" echo RkFVTFRfVEFSR0VUIicpCiAgICBhcCgnaWYgWyAiJHtUQVJHRVQjXFx+fSIgIT0gIiRUQVJHRVQi
>> "!B64TMP!" echo IF07IHRoZW4gVEFSR0VUPSIkSE9NRSR7VEFSR0VUI1xcfn0iOyBmaSAgIyBQT1NJWCB0aWxkZSBl
>> "!B64TMP!" echo eHBhbnNpb24nKQogICAgYXAoJ21rZGlyIC1wICIkVEFSR0VUIicpCiAgICBhcCgnVEFSR0VUPSIk
>> "!B64TMP!" echo KGNkICIkVEFSR0VUIiAmJiBwd2QpIicpCiAgICBhcCgnc2F5ICIgIFVzaW5nOiAkVEFSR0VUIicp
>> "!B64TMP!" echo CiAgICBhcCgnJykKICAgIGFwKCd2YWxpZGF0ZV9wb3J0KCkgeycpCiAgICBhcCgnICBsb2NhbCBw
>> "!B64TMP!" echo PSIkMSInKQogICAgYXAoJyAgW1sgIiRwIiA9fiBeWzAtOV0rJCBdXSB8fCByZXR1cm4gMScpCiAg
>> "!B64TMP!" echo ICBhcCgnICBbICIkcCIgLWdlIDEgXSAyPi9kZXYvbnVsbCB8fCByZXR1cm4gMScpCiAgICBhcCgn
>> "!B64TMP!" echo ICBbICIkcCIgLWxlIDY1NTM1IF0gMj4vZGV2L251bGwgfHwgcmV0dXJuIDEnKQogICAgYXAoJyAg
>> "!B64TMP!" echo cmV0dXJuIDAnKQogICAgYXAoJ30nKQogICAgYXAoJycpCiAgICBhcCgnaGRyICJTdGVwIDIgb2Yg
>> "!B64TMP!" echo NTogU2VhclhORyBwb3J0IChkZWZhdWx0IDk5OTApIicpCiAgICBhcCgnd2hpbGUgdHJ1ZTsgZG8n
>> "!B64TMP!" echo KQogICAgYXAoJyAgcHJpbnRmICIgIFBvcnQgZm9yIFNlYXJYTkcgW3ByZXNzIEVudGVyIGZvciA5
>> "!B64TMP!" echo OTkwXTogIicpCiAgICBhcCgnICByZWFkIC1yIFNFQVJYTkdfUE9SVCcpCiAgICBhcCgnICBbIC16
>> "!B64TMP!" echo ICIkU0VBUlhOR19QT1JUIiBdICYmIFNFQVJYTkdfUE9SVD05OTkwJykKICAgIGFwKCcgIGlmIHZh
>> "!B64TMP!" echo bGlkYXRlX3BvcnQgIiRTRUFSWE5HX1BPUlQiOyB0aGVuIGJyZWFrOyBmaScpCiAgICBhcCgnICBz
>> "!B64TMP!" echo YXkgIiAgJHtZRUxMT1d9WyFdJHtSRVNFVH0gXCckU0VBUlhOR19QT1JUXCcgaXMgbm90IGEgdmFs
>> "!B64TMP!" echo aWQgcG9ydCAoMS02NTUzNSkuIicpCiAgICBhcCgnZG9uZScpCiAgICBhcCgnJykKICAgIGFwKCdo
>> "!B64TMP!" echo ZHIgIlN0ZXAgMyBvZiA1OiBGaXJlY3Jhd2wgcG9ydCAoZGVmYXVsdCA5OTkxKSInKQogICAgYXAo
>> "!B64TMP!" echo J3doaWxlIHRydWU7IGRvJykKICAgIGFwKCcgIHByaW50ZiAiICBQb3J0IGZvciBGaXJlY3Jhd2wg
>> "!B64TMP!" echo W3ByZXNzIEVudGVyIGZvciA5OTkxXTogIicpCiAgICBhcCgnICByZWFkIC1yIEZJUkVDUkFXTF9Q
>> "!B64TMP!" echo T1JUJykKICAgIGFwKCcgIFsgLXogIiRGSVJFQ1JBV0xfUE9SVCIgXSAmJiBGSVJFQ1JBV0xfUE9S
>> "!B64TMP!" echo VD05OTkxJykKICAgIGFwKCcgIGlmICEgdmFsaWRhdGVfcG9ydCAiJEZJUkVDUkFXTF9QT1JUIjsg
>> "!B64TMP!" echo dGhlbicpCiAgICBhcCgnICAgIHNheSAiICAke1lFTExPV31bIV0ke1JFU0VUfSBcJyRGSVJFQ1JB
>> "!B64TMP!" echo V0xfUE9SVFwnIGlzIG5vdCBhIHZhbGlkIHBvcnQgKDEtNjU1MzUpLiInKQogICAgYXAoJyAgICBj
>> "!B64TMP!" echo b250aW51ZScpCiAgICBhcCgnICBmaScpCiAgICBhcCgnICBpZiBbICIkRklSRUNSQVdMX1BPUlQi
>> "!B64TMP!" echo ID0gIiRTRUFSWE5HX1BPUlQiIF07IHRoZW4nKQogICAgYXAoJyAgICBzYXkgIiAgJHtZRUxMT1d9
>> "!B64TMP!" echo WyFdJHtSRVNFVH0gRmlyZWNyYXdsIHBvcnQgbXVzdCBkaWZmZXIgZnJvbSBTZWFyWE5HIHBvcnQu
>> "!B64TMP!" echo IicpCiAgICBhcCgnICAgIGNvbnRpbnVlJykKICAgIGFwKCcgIGZpJykKICAgIGFwKCcgIGJyZWFr
>> "!B64TMP!" echo JykKICAgIGFwKCdkb25lJykKICAgIGFwKCcnKQogICAgYXAoJ2hkciAiU3RlcCA0IG9mIDU6IExv
>> "!B64TMP!" echo Y2FsIExMTSAob3B0aW9uYWwpIicpCiAgICBhcCgnc2F5ICIgIExldHMgRmlyZWNyYXdsIGRvIEFJ
>> "!B64TMP!" echo IGV4dHJhY3Rpb24gKC92MS9leHRyYWN0KSBhbmQgc3VtbWFyaWVzLiInKQogICAgYXAoJ3NheSAi
>> "!B64TMP!" echo ICBSZWNvbW1lbmRlZDogTE0gU3R1ZGlvIC0+IGh0dHA6Ly9sb2NhbGhvc3Q6MTIzNC92MSInKQog
>> "!B64TMP!" echo ICAgYXAoJ3ByaW50ZiAiICBDb25uZWN0IGEgbG9jYWwgTExNIG5vdz8gW3kvTl06ICInKQogICAg
>> "!B64TMP!" echo YXAoJ3JlYWQgLXIgVVNFX0xMTScpCiAgICBhcCgnT1BFTkFJX0JBU0VfVVJMPSIiOyBPUEVOQUlf
>> "!B64TMP!" echo QVBJX0tFWT0iIjsgTU9ERUxfTkFNRT0iIicpCiAgICBhcCgnaWYgWyAiJChsb3dlciAiJFVTRV9M
>> "!B64TMP!" echo TE0iKSIgPSAieSIgXTsgdGhlbicpCiAgICBhcCgnICBwcmludGYgIiAgICBMTSBTdHVkaW8gc2Vy
>> "!B64TMP!" echo dmVyIFVSTCAoYXMgc2hvd24gaW4gTE0gU3R1ZGlvKSBbcHJlc3MgRW50ZXIgZm9yIGh0dHA6Ly9s
>> "!B64TMP!" echo b2NhbGhvc3Q6MTIzNC92MV06ICInKQogICAgYXAoJyAgcmVhZCAtciBMTE1fVVJMJykKICAgIGFw
>> "!B64TMP!" echo KCcgIFsgLXogIiRMTE1fVVJMIiBdICYmIExMTV9VUkw9Imh0dHA6Ly9sb2NhbGhvc3Q6MTIzNC92
>> "!B64TMP!" echo MSInKQogICAgYXAoJyAgcHJpbnRmICIgICAgTW9kZWwgbmFtZSAoaWQgbG9hZGVkIGluIExNIFN0
>> "!B64TMP!" echo dWRpbykgW3ByZXNzIEVudGVyIHRvIHNraXBdOiAiJykKICAgIGFwKCcgIHJlYWQgLXIgTExNX01P
>> "!B64TMP!" echo REVMJykKICAgIGFwKCcgIE9QRU5BSV9CQVNFX1VSTD0iJHtMTE1fVVJML2h0dHA6XFwvXFwvbG9j
>> "!B64TMP!" echo YWxob3N0L2h0dHA6XFwvXFwvaG9zdC5kb2NrZXIuaW50ZXJuYWx9IicpCiAgICBhcCgnICBPUEVO
>> "!B64TMP!" echo QUlfQkFTRV9VUkw9IiR7T1BFTkFJX0JBU0VfVVJML2h0dHA6XFwvXFwvMTI3LjAuMC4xL2h0dHA6
>> "!B64TMP!" echo XFwvXFwvaG9zdC5kb2NrZXIuaW50ZXJuYWx9IicpCiAgICBhcCgnICBPUEVOQUlfQVBJX0tFWT0i
>> "!B64TMP!" echo bG0tc3R1ZGlvIicpCiAgICBhcCgnICBbIC1uICIkTExNX01PREVMIiBdICYmIE1PREVMX05BTUU9
>> "!B64TMP!" echo IiRMTE1fTU9ERUwiJykKICAgIGFwKCcgIHNheSAiICAgIChDb250YWluZXIgd2lsbCByZWFjaCBp
>> "!B64TMP!" echo dCBhdDogJE9QRU5BSV9CQVNFX1VSTCkiJykKICAgIGFwKCcgIHNheSAiICAgIChNYWtlIHN1cmUg
>> "!B64TMP!" echo TE0gU3R1ZGlvIGhhcyBcJ1NlcnZlIG9uIGxvY2FsIG5ldHdvcmtcJyBlbmFibGVkLikiJykKICAg
>> "!B64TMP!" echo IGFwKCdmaScpCiAgICBhcCgnJykKICAgICMgU3RlcCA1OiBvcHRpb25hbCBGaXJlY3Jhd2wgYWNj
>> "!B64TMP!" echo b3VudCAodW5sb2NrcyB0aGUgYWNjb3VudC1nYXRlZCB0b29scykKICAgIGFwKCdoZHIgIlN0ZXAg
>> "!B64TMP!" echo NSBvZiA1OiBGaXJlY3Jhd2wgYWNjb3VudCAob3B0aW9uYWwpIicpCiAgICBhcCgnc2F5ICIgIFRo
>> "!B64TMP!" echo ZSBleHRyYSB0b29scyAocmVzZWFyY2ggYWdlbnQsIGxpdmUtcGFnZSBpbnRlcmFjdCwgZmlsZSBw
>> "!B64TMP!" echo YXJzZSwiJykKICAgIGFwKCdzYXkgIiAgbW9uaXRvcnMsIHBhcGVyIHJlc2VhcmNoLCBHaXRIdWIv
>> "!B64TMP!" echo ZGV2ZWxvcGVyIHNlYXJjaCkgb25seSB3b3JrIicpCiAgICBhcCgnc2F5ICIgIHdpdGggYSBGaXJl
>> "!B64TMP!" echo Y3Jhd2wgYWNjb3VudCBBUEkga2V5IChwYWlkIGNsb3VkIHNlcnZpY2UpOiInKQogICAgYXAoJ3Nh
>> "!B64TMP!" echo eSAiICAgIGh0dHBzOi8vd3d3LmZpcmVjcmF3bC5kZXYiJykKICAgIGFwKCdzYXkgIiAgQW5zd2Vy
>> "!B64TMP!" echo IE4gdG8gaW5zdGFsbCBvbmx5IHRoZSBmcmVlIGxvY2FsIHRvb2xzIChkZWZhdWx0KS4iJykKICAg
>> "!B64TMP!" echo IGFwKCdwcmludGYgIiAgQWRkIGEgRmlyZWNyYXdsIGFjY291bnQgbm93PyBbeS9OXTogIicpCiAg
>> "!B64TMP!" echo ICBhcCgnVVNFX0ZDPSIiJykKICAgIGFwKCdyZWFkIC1yIFVTRV9GQyB8fCBVU0VfRkM9IiInKQog
>> "!B64TMP!" echo ICAgYXAoJ0ZDX0FQSV9LRVk9IiI7IEZDX0FQSV9VUkw9IiInKQogICAgYXAoJ2lmIFsgIiQobG93
>> "!B64TMP!" echo ZXIgIiRVU0VfRkMiKSIgPSAieSIgXTsgdGhlbicpCiAgICBhcCgnICBGQ19UUklFUz0wJykKICAg
>> "!B64TMP!" echo IGFwKCcgIHdoaWxlIHRydWU7IGRvJykKICAgIGFwKCcgICAgcHJpbnRmICIgICAgRmlyZWNyYXds
>> "!B64TMP!" echo IEFQSSBrZXkgKGZyb20gaHR0cHM6Ly93d3cuZmlyZWNyYXdsLmRldik6ICInKQogICAgYXAoJyAg
>> "!B64TMP!" echo ICBpZiAhIHJlYWQgLXIgRkNfQVBJX0tFWTsgdGhlbiBGQ19BUElfS0VZPSIiOyBicmVhazsgZmkn
>> "!B64TMP!" echo KQogICAgYXAoJyAgICBbIC1uICIkRkNfQVBJX0tFWSIgXSAmJiBicmVhaycpCiAgICBhcCgnICAg
>> "!B64TMP!" echo IEZDX1RSSUVTPSQoKEZDX1RSSUVTICsgMSkpJykKICAgIGFwKCcgICAgaWYgWyAiJEZDX1RSSUVT
>> "!B64TMP!" echo IiAtZ2UgMyBdOyB0aGVuJykKICAgIGFwKCcgICAgICBzYXkgIiAgICAke1lFTExPV31bIV0ke1JF
>> "!B64TMP!" echo U0VUfSBubyBBUEkga2V5IGVudGVyZWQgLSBjb250aW51aW5nIFdJVEhPVVQgYSBGaXJlY3Jhd2wg
>> "!B64TMP!" echo YWNjb3VudC4iJykKICAgIGFwKCcgICAgICBGQ19BUElfS0VZPSIiJykKICAgIGFwKCcgICAgICBi
>> "!B64TMP!" echo cmVhaycpCiAgICBhcCgnICAgIGZpJykKICAgIGFwKCcgICAgc2F5ICIgICAgJHtZRUxMT1d9WyFd
>> "!B64TMP!" echo JHtSRVNFVH0gdGhlIEFQSSBrZXkgY2Fubm90IGJlIGVtcHR5IC0gdHJ5IGFnYWluLiInKQogICAg
>> "!B64TMP!" echo YXAoJyAgZG9uZScpCiAgICBhcCgnICBpZiBbIC1uICIkRkNfQVBJX0tFWSIgXTsgdGhlbicpCiAg
>> "!B64TMP!" echo ICBhcCgnICAgIHByaW50ZiAiICAgIEZpcmVjcmF3bCBBUEkgVVJMIFtwcmVzcyBFbnRlciBmb3Ig
>> "!B64TMP!" echo aHR0cHM6Ly9hcGkuZmlyZWNyYXdsLmRldl06ICInKQogICAgYXAoJyAgICByZWFkIC1yIEZDX0FQ
>> "!B64TMP!" echo SV9VUkwgfHwgRkNfQVBJX1VSTD0iIicpCiAgICBhcCgnICAgIFsgLXogIiRGQ19BUElfVVJMIiBd
>> "!B64TMP!" echo ICYmIEZDX0FQSV9VUkw9Imh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYiJykKICAgIGFwKCcgIGZp
>> "!B64TMP!" echo JykKICAgIGFwKCdmaScpCiAgICBhcCgnJykKICAgICMgU3VtbWFyeSArIGNvbmZpcm0KICAgIGFw
>> "!B64TMP!" echo KCdlY2hvJykKICAgIGFwKCdzYXkgIiR7Qk9MRH09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0ke1JFU0VUfSInKQogICAgYXAoJ3NheSAi
>> "!B64TMP!" echo JHtCT0xEfSAgU3VtbWFyeSR7UkVTRVR9IicpCiAgICBhcCgnc2F5ICIgIEZvbGRlcjogICAgICAg
>> "!B64TMP!" echo ICAkVEFSR0VUIicpCiAgICBhcCgnc2F5ICIgIFNlYXJYTkcgcG9ydDogICAkU0VBUlhOR19QT1JU
>> "!B64TMP!" echo IicpCiAgICBhcCgnc2F5ICIgIEZpcmVjcmF3bCBwb3J0OiAkRklSRUNSQVdMX1BPUlQiJykKICAg
>> "!B64TMP!" echo IGFwKCdzYXkgIiAgQWdlbnQgc2tpbGw6ICAgICRIT01FLy5hZ2VudHMvc2tpbGxzL2xvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2giJykKICAgIGFwKCdpZiBbIC1uICIkT1BFTkFJX0JBU0VfVVJMIiBdOyB0aGVuJykK
>> "!B64TMP!" echo ICAgIGFwKCcgIHNheSAiICBMTE0gZW5kcG9pbnQ6ICAgJE9QRU5BSV9CQVNFX1VSTCAgJE1PREVM
>> "!B64TMP!" echo X05BTUUiJykKICAgIGFwKCdlbHNlJykKICAgIGFwKCcgIHNheSAiICBMTE0gZW5kcG9pbnQ6ICAg
>> "!B64TMP!" echo KG5vbmUgLSBlbmFibGUgbGF0ZXIgYnkgZWRpdGluZyAuZW52KSInKQogICAgYXAoJ2ZpJykKICAg
>> "!B64TMP!" echo IGFwKCdpZiBbIC1uICIkRkNfQVBJX0tFWSIgXTsgdGhlbicpCiAgICBhcCgnICBzYXkgIiAgRmly
>> "!B64TMP!" echo ZWNyYXdsIGFjY3Q6ICRGQ19BUElfVVJMICAoYWNjb3VudCB0b29scyBpbnN0YWxsZWQpIicpCiAg
>> "!B64TMP!" echo ICBhcCgnZWxzZScpCiAgICBhcCgnICBzYXkgIiAgRmlyZWNyYXdsIGFjY3Q6IChub25lIC0gZnJl
>> "!B64TMP!" echo ZSBsb2NhbCB0b29scyBvbmx5KSInKQogICAgYXAoJ2ZpJykKICAgIGFwKCdzYXkgIiR7Qk9MRH09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT0ke1JFU0VUfSInKQogICAgYXAoJ3ByaW50ZiAiUHJvY2VlZCB3aXRoIGluc3RhbGw/IFtZL25d
>> "!B64TMP!" echo OiAiJykKICAgIGFwKCdyZWFkIC1yIENPTkZJUk0nKQogICAgYXAoJ2lmIFsgIiQobG93ZXIgIiRD
>> "!B64TMP!" echo T05GSVJNIikiID0gIm4iIF07IHRoZW4gc2F5ICJJbnN0YWxsIGNhbmNlbGxlZC4iOyBleGl0IDA7
>> "!B64TMP!" echo IGZpJykKICAgIGFwKCcnKQogICAgIyBDcmVhdGUgZm9sZGVycwogICAgYXAoJ21rZGlyIC1wICIk
>> "!B64TMP!" echo VEFSR0VUL2NvbmZpZy9zZWFyeG5nIiAiJFRBUkdFVC9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMi
>> "!B64TMP!" echo JykKICAgIGFwKCcnKQogICAgIyBCYWNrdXAgZXhpc3RpbmcgLmVudgogICAgYXAoJ2lmIFsgLWYg
>> "!B64TMP!" echo IiRUQVJHRVQvLmVudiIgXTsgdGhlbicpCiAgICBhcCgnICBMRFQ9IiQoZGF0ZSArJVklbSVkJUgl
>> "!B64TMP!" echo TSVTKSInKQogICAgYXAoJyAgY3AgIiRUQVJHRVQvLmVudiIgIiRUQVJHRVQvLmVudi5iYWsuJExE
>> "!B64TMP!" echo VCInKQogICAgYXAoJyAgc2F5ICIgIEJhY2tlZCB1cCBleGlzdGluZyAuZW52IHRvIC5lbnYuYmFr
>> "!B64TMP!" echo LiRMRFQiJykKICAgIGFwKCdmaScpCiAgICBhcCgnJykKICAgICMgLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAgIyAg
>> "!B64TMP!" echo TWF0ZXJpYWxpc2UgZXZlcnkgcHJvamVjdCBmaWxlOiBjb3B5IGZyb20gc291cmNlIGlmIHByZXNl
>> "!B64TMP!" echo bnQsIGVsc2UKICAgICMgIHVzZSB0aGUgZW1iZWRkZWQgaGVyZWRvYyBmb3IgdGhhdCBmaWxlLgog
>> "!B64TMP!" echo ICAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tCiAgICBhcCgnc2F5ICJDb3B5aW5nIGFsbCBwcm9qZWN0IGZpbGVzLi4u
>> "!B64TMP!" echo IicpCgogICAgZm9yIHJlbCwgc3JjIGluIEZJTEVTOgogICAgICAgIGRhdGEgPSByZWFkKHNyYykK
>> "!B64TMP!" echo ICAgICAgICB0ZXh0ID0gZGF0YS5kZWNvZGUoInV0Zi04IikKICAgICAgICB0YWcgPSAiRU9GXyIg
>> "!B64TMP!" echo KyAiIi5qb2luKGMgaWYgYy5pc2FsbnVtKCkgZWxzZSAiXyIgZm9yIGMgaW4gcmVsKS51cHBlcigp
>> "!B64TMP!" echo CiAgICAgICAgYXAoJycpCiAgICAgICAgYXAoJyMgLS0tICcgKyByZWwgKyAnIC0tLScpCiAgICAg
>> "!B64TMP!" echo ICAgYXAoJ2lmIFsgLWYgIiRTUkMvJyArIHJlbCArICciIF07IHRoZW4nKQogICAgICAgIGFwKCcg
>> "!B64TMP!" echo IGNwICIkU1JDLycgKyByZWwgKyAnIiAiJFRBUkdFVC8nICsgcmVsICsgJyInKQogICAgICAgIGFw
>> "!B64TMP!" echo KCdlbHNlJykKICAgICAgICBhcCgnICBzYXkgIiAgW2VtYmVkZGVkXSAnICsgcmVsICsgJyAgKHNv
>> "!B64TMP!" echo dXJjZSBub3QgZm91bmQgbmV4dCB0byBpbnN0YWxsZXI7IHVzaW5nIGJ1aWx0LWluIGNvcHkpIicp
>> "!B64TMP!" echo CiAgICAgICAgYXAoJyAgY2F0ID4gIiRUQVJHRVQvJyArIHJlbCArICciIDw8XCcnICsgdGFnICsg
>> "!B64TMP!" echo J1wnJykKICAgICAgICAjIE5vcm1hbGlzZSBsaW5lIGVuZGluZ3MgdG8gTEYgaW4gdGhlIGhlcmVk
>> "!B64TMP!" echo b2MgYm9keSBzbyB0aGUgcnVudGltZQogICAgICAgICMgQ1JMRi1jb252ZXJzaW9uIGxvb3AgcHJv
>> "!B64TMP!" echo ZHVjZXMgY2xlYW4gQ1JMRiAobm90IFxyXHJcbikgZm9yIC5iYXQgZmlsZXMuCiAgICAgICAgIyBz
>> "!B64TMP!" echo cGxpdGxpbmVzKCkgYXZvaWRzIGEgc3B1cmlvdXMgdHJhaWxpbmcgZW1wdHkgbGluZSB0aGF0IHdv
>> "!B64TMP!" echo dWxkCiAgICAgICAgIyBvdGhlcndpc2UgYWRkIGEgYmxhbmsgbGluZSBhdCB0aGUgZW5kIG9mIGV2
>> "!B64TMP!" echo ZXJ5IGVtYmVkZGVkIGZpbGUuCiAgICAgICAgdGV4dF9sZiA9IHRleHQucmVwbGFjZSgiXHJcbiIs
>> "!B64TMP!" echo ICJcbiIpLnJlcGxhY2UoIlxyIiwgIlxuIikKICAgICAgICBmb3IgbGluZSBpbiB0ZXh0X2xmLnNw
>> "!B64TMP!" echo bGl0bGluZXMoKToKICAgICAgICAgICAgYXAobGluZSkKICAgICAgICBhcCh0YWcpCiAgICAgICAg
>> "!B64TMP!" echo YXAoJ2ZpJykKCiAgICAjIGluY2x1ZGUgdGhlIGluc3RhbGxlcnMgdGhlbXNlbHZlcwogICAgYXAo
>> "!B64TMP!" echo J1sgLWYgIiRTUkMvaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giIF0gJiYgY3AgIiRTUkMvaW5zdGFs
>> "!B64TMP!" echo bC1sb2NhbC1zZWFyY2guc2giICIkVEFSR0VUL2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoIicpCiAg
>> "!B64TMP!" echo ICBhcCgnWyAtZiAiJFNSQy9pbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQiIF0gJiYgY3AgIiRTUkMv
>> "!B64TMP!" echo aW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IiAiJFRBUkdFVC9pbnN0YWxsLWxvY2FsLXNlYXJjaC5i
>> "!B64TMP!" echo YXQiJykKICAgIGFwKCcjIEFsd2F5cyBhbHNvIGRyb3AgdGhlICpjdXJyZW50KiBpbnN0YWxsZXIg
>> "!B64TMP!" echo KHRoaXMgc2NyaXB0KSBpbnRvIHRhcmdldCwgZXZlbicpCiAgICBhcCgnIyBpZiBpdCB3YXMgcmVu
>> "!B64TMP!" echo YW1lZCAodGhlIGNoZWNrIGFib3ZlIGxvb2tzIGZvciB0aGUgY2Fub25pY2FsIG5hbWUpLicpCiAg
>> "!B64TMP!" echo ICBhcCgnY3AgLWYgIiQwIiAiJFRBUkdFVC9pbnN0YWxsLWxvY2FsLXNlYXJjaC5zaCIgMj4vZGV2
>> "!B64TMP!" echo L251bGwgfHwgdHJ1ZScpCiAgICBhcCgnY2htb2QgK3ggIiRUQVJHRVQiLyouc2ggMj4vZGV2L251
>> "!B64TMP!" echo bGwgfHwgdHJ1ZScpCiAgICBhcCgnJykKICAgICMgRW5zdXJlIGV2ZXJ5IC5iYXQgZmlsZSBpbiBU
>> "!B64TMP!" echo QVJHRVQgaGFzIENSTEYgbGluZSBlbmRpbmdzIChXaW5kb3dzIGNtZCBpcwogICAgIyBoYXBwaWVy
>> "!B64TMP!" echo IHdpdGggQ1JMRjsgdGhlIGhlcmVkb2NzIGFib3ZlIHdyb3RlIExGLCB3aGljaCB3b3JrcyBidXQg
>> "!B64TMP!" echo aXNuJ3QKICAgICMgaWRlYWwgd2hlbiB0aGUgZm9sZGVyIGlzIGxhdGVyIGNvcGllZCB0byBhIFdp
>> "!B64TMP!" echo bmRvd3MgbWFjaGluZSkuCiAgICAjIFRoZSBzZWQgaXMgaWRlbXBvdGVudDogc3RyaXAgYW55IHRy
>> "!B64TMP!" echo YWlsaW5nIENSIGZpcnN0LCB0aGVuIGFkZCBvbmUgYmFjaywKICAgICMgc28gZmlsZXMgY29waWVk
>> "!B64TMP!" echo IGZyb20gc291cmNlIChhbHJlYWR5IENSTEYpIGFyZSBub3QgZG91YmxlLWNvbnZlcnRlZC4KICAg
>> "!B64TMP!" echo IGFwKCdmb3IgZiBpbiAiJFRBUkdFVCIvKi5iYXQ7IGRvJykKICAgIGFwKCcgIFsgLWYgIiRmIiBd
>> "!B64TMP!" echo IHx8IGNvbnRpbnVlJykKICAgIGFwKCcgIGlmIGNvbW1hbmQgLXYgYXdrID4vZGV2L251bGwgMj4m
>> "!B64TMP!" echo MTsgdGhlbicpCiAgICBhcCgnICAgIGF3ayBcJ3tzdWIoL1xcciQvLCIiKTsgcHJpbnRmICIlc1xc
>> "!B64TMP!" echo clxcbiIsICQwfVwnICIkZiIgPiAiJGYuY3JsZiIgMj4vZGV2L251bGwgJiYgbXYgIiRmLmNybGYi
>> "!B64TMP!" echo ICIkZiIgfHwgcm0gLWYgIiRmLmNybGYiJykKICAgIGFwKCcgIGZpJykKICAgIGFwKCdkb25lJykK
>> "!B64TMP!" echo ICAgIGFwKCcnKQogICAgIyBHZW5lcmF0ZSBzZWNyZXRzCiAgICBhcCgnc2F5ICJHZW5lcmF0aW5n
>> "!B64TMP!" echo IHNlY3VyZSBjcmVkZW50aWFscy4uLiInKQogICAgYXAoJ2dlbmtleSgpIHsnKQogICAgYXAoJyAg
>> "!B64TMP!" echo aWYgY29tbWFuZCAtdiBvcGVuc3NsID4vZGV2L251bGwgMj4mMTsgdGhlbiBvcGVuc3NsIHJhbmQg
>> "!B64TMP!" echo LWhleCAzMicpCiAgICBhcCgnICBlbHNlIGhlYWQgLWMgMzIgL2Rldi91cmFuZG9tIHwgb2QgLUFu
>> "!B64TMP!" echo IC10eDEgfCB0ciAtZCBcJyBcXG5cJzsgZmknKQogICAgYXAoJ30nKQogICAgYXAoJ1NFQ1JFVD0i
>> "!B64TMP!" echo JChnZW5rZXkpIjsgQlVMTD0iJChnZW5rZXkpIjsgUEdQQVNTPSIkKGdlbmtleSkiOyBSQUJQQVNT
>> "!B64TMP!" echo PSIkKGdlbmtleSkiOyBCTEVTU1RPS0VOPSIkKGdlbmtleSkiJykKICAgIGFwKCcnKQogICAgIyBX
>> "!B64TMP!" echo cml0ZSAuZW52CiAgICBhcCgnc2F5ICJXcml0aW5nIC5lbnYgLi4uIicpCiAgICBhcCgneycpCiAg
>> "!B64TMP!" echo ICBhcCgnICBlY2hvICIjIExvY2FsIFNlYXJjaCBjb25maWd1cmF0aW9uIC0gZ2VuZXJhdGVkIGJ5
>> "!B64TMP!" echo IGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIicpCiAgICBhcCgnICBlY2hvICIjIEVkaXQgcG9ydHMv
>> "!B64TMP!" echo TExNIGhlcmUsIHRoZW4gcnVuIHVwZGF0ZS5zaCB0byBhcHBseS4iJykKICAgIGFwKCcgIGVjaG8n
>> "!B64TMP!" echo KQogICAgYXAoJyAgZWNobyAiIyAtLS0tIEhvc3QgcG9ydHMgLS0tLSInKQogICAgYXAoJyAgZWNo
>> "!B64TMP!" echo byAiU0VBUlhOR19QT1JUPSRTRUFSWE5HX1BPUlQiJykKICAgIGFwKCcgIGVjaG8gIkZJUkVDUkFX
>> "!B64TMP!" echo TF9QT1JUPSRGSVJFQ1JBV0xfUE9SVCInKQogICAgYXAoJyAgZWNobycpCiAgICBhcCgnICBlY2hv
>> "!B64TMP!" echo ICIjIC0tLS0gU2VhclhORyBpbnN0YW5jZSBzZWNyZXQgLS0tLSInKQogICAgYXAoJyAgZWNobyAi
>> "!B64TMP!" echo U0VBUlhOR19TRUNSRVQ9JFNFQ1JFVCInKQogICAgYXAoJyAgZWNobycpCiAgICBhcCgnICBlY2hv
>> "!B64TMP!" echo ICIjIC0tLS0gRmlyZWNyYXdsIGludGVybmFsIGNyZWRlbnRpYWxzIC0tLS0iJykKICAgIGFwKCcg
>> "!B64TMP!" echo IGVjaG8gIkJVTExfQVVUSF9LRVk9JEJVTEwiJykKICAgIGFwKCcgIGVjaG8gIlBPU1RHUkVTX0RC
>> "!B64TMP!" echo PWZpcmVjcmF3bCInKQogICAgYXAoJyAgZWNobyAiUE9TVEdSRVNfVVNFUj1maXJlY3Jhd2wiJykK
>> "!B64TMP!" echo ICAgIGFwKCcgIGVjaG8gIlBPU1RHUkVTX1BBU1NXT1JEPSRQR1BBU1MiJykKICAgIGFwKCcgIGVj
>> "!B64TMP!" echo aG8gIlJBQkJJVE1RX1VTRVI9ZmlyZWNyYXdsIicpCiAgICBhcCgnICBlY2hvICJSQUJCSVRNUV9Q
>> "!B64TMP!" echo QVNTV09SRD0kUkFCUEFTUyInKQogICAgYXAoJyAgZWNobycpCiAgICBhcCgnICBlY2hvICIjIC0t
>> "!B64TMP!" echo LS0gQnJvd3Nlcmxlc3MgKHN0ZWFsdGggaGVhZGxlc3MgQ2hyb21pdW0pIC0tLS0iJykKICAgIGFw
>> "!B64TMP!" echo KCcgIGVjaG8gIkJST1dTRVJMRVNTX1RPS0VOPSRCTEVTU1RPS0VOIicpCiAgICBhcCgnICBlY2hv
>> "!B64TMP!" echo JykKICAgIGFwKCcgIGVjaG8gIkxPR0dJTkdfTEVWRUw9aW5mbyInKQogICAgYXAoJyAgaWYgWyAt
>> "!B64TMP!" echo biAiJE9QRU5BSV9CQVNFX1VSTCIgXTsgdGhlbicpCiAgICBhcCgnICAgIGVjaG8nKQogICAgYXAo
>> "!B64TMP!" echo JyAgICBlY2hvICIjIC0tLS0gTG9jYWwgTExNIGZvciBGaXJlY3Jhd2wgQUkgZmVhdHVyZXMgLS0t
>> "!B64TMP!" echo LSInKQogICAgYXAoJyAgICBlY2hvICJPUEVOQUlfQkFTRV9VUkw9JE9QRU5BSV9CQVNFX1VSTCIn
>> "!B64TMP!" echo KQogICAgYXAoJyAgICBlY2hvICJPUEVOQUlfQVBJX0tFWT0kT1BFTkFJX0FQSV9LRVkiJykKICAg
>> "!B64TMP!" echo IGFwKCcgICAgWyAtbiAiJE1PREVMX05BTUUiIF0gJiYgZWNobyAiTU9ERUxfTkFNRT0kTU9ERUxf
>> "!B64TMP!" echo TkFNRSInKQogICAgYXAoJyAgZmknKQogICAgYXAoJyAgaWYgWyAtbiAiJEZDX0FQSV9LRVkiIF07
>> "!B64TMP!" echo IHRoZW4nKQogICAgYXAoJyAgICBlY2hvJykKICAgIGFwKCcgICAgZWNobyAiIyAtLS0tIEZpcmVj
>> "!B64TMP!" echo cmF3bCBhY2NvdW50IChjbG91ZCBBUEkpIGZvciBhY2NvdW50LW9ubHkgdG9vbHMgLS0tLSInKQog
>> "!B64TMP!" echo ICAgYXAoJyAgICBlY2hvICJGSVJFQ1JBV0xfQVBJX1VSTD0kRkNfQVBJX1VSTCInKQogICAgYXAo
>> "!B64TMP!" echo JyAgICBlY2hvICJGSVJFQ1JBV0xfQVBJX0tFWT0kRkNfQVBJX0tFWSInKQogICAgYXAoJyAgZmkn
>> "!B64TMP!" echo KQogICAgYXAoJ30gPiAiJFRBUkdFVC8uZW52IicpCiAgICBhcCgnJykKICAgICMgSW5qZWN0IHNl
>> "!B64TMP!" echo Y3JldAogICAgYXAoJ3NheSAiSW5qZWN0aW5nIFNlYXJYTkcgc2VjcmV0IGludG8gc2V0dGluZ3Mu
>> "!B64TMP!" echo eW1sIC4uLiInKQogICAgYXAoJ1NGSUxFPSIkVEFSR0VUL2NvbmZpZy9zZWFyeG5nL3NldHRpbmdz
>> "!B64TMP!" echo LnltbCInKQogICAgYXAoJ3NlZCAicy9fX1NFQVJYTkdfU0VDUkVUX1BMQUNFSE9MREVSX18vJFNF
>> "!B64TMP!" echo Q1JFVC8iICIkU0ZJTEUiID4gIiRTRklMRS50bXAiICYmIG12ICIkU0ZJTEUudG1wIiAiJFNGSUxF
>> "!B64TMP!" echo IicpCiAgICBhcCgnJykKICAgICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICAgIyAgQ29yZS1vbmx5IHRyaW06IHdp
>> "!B64TMP!" echo dGhvdXQgYSBGaXJlY3Jhd2wgYWNjb3VudCwgcmVtb3ZlIHRoZSAxOQogICAgIyAgYWNjb3VudC1n
>> "!B64TMP!" echo YXRlZCBzY3JpcHRzIGZyb20gdGhlIGJ1bmRsZWQgc2tpbGwgYW5kIHN3YXAgaW4gdGhlCiAgICAj
>> "!B64TMP!" echo ICBjb3JlLW9ubHkgU0tJTEwubWQgc28gdGhlIGluc3RhbGxlZCBza2lsbCBtYXRjaGVzIHdoYXQg
>> "!B64TMP!" echo d29ya3MuCiAgICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAgIGFwKCdpZiBbIC16ICIkRkNfQVBJX0tFWSIgXTsg
>> "!B64TMP!" echo dGhlbicpCiAgICBhcCgnICBzYXkgIkluc3RhbGxpbmcgdGhlIGNvcmUtb25seSBsb2NhbC13ZWIt
>> "!B64TMP!" echo c2VhcmNoIHNraWxsIChubyBGaXJlY3Jhd2wgYWNjb3VudCkuLi4iJykKICAgIGZvciBuYW1lIGlu
>> "!B64TMP!" echo IEFDQ09VTlRfVE9PTFM6CiAgICAgICAgYXAoJyAgcm0gLWYgIiRUQVJHRVQvbG9jYWwtd2ViLXNl
>> "!B64TMP!" echo YXJjaC9zY3JpcHRzLycgKyBuYW1lICsgJyInKQogICAgYXAoJyAgaWYgWyAtZiAiJFRBUkdFVC9s
>> "!B64TMP!" echo b2NhbC13ZWItc2VhcmNoL1NLSUxMLWNvcmUubWQiIF07IHRoZW4gY3AgLWYgIiRUQVJHRVQvbG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaC9TS0lMTC1jb3JlLm1kIiAiJFRBUkdFVC9sb2NhbC13ZWItc2VhcmNoL1NL
>> "!B64TMP!" echo SUxMLm1kIjsgZmknKQogICAgYXAoJ2ZpJykKICAgIGFwKCcjIFNLSUxMLWNvcmUubWQgaXMgYSBi
>> "!B64TMP!" echo dWlsZC10aW1lIHZhcmlhbnQgLSBuZXZlciBwYXJ0IG9mIGFuIGluc3RhbGxlZCBza2lsbC4nKQog
>> "!B64TMP!" echo ICAgYXAoJ3JtIC1mICIkVEFSR0VUL2xvY2FsLXdlYi1zZWFyY2gvU0tJTEwtY29yZS5tZCInKQog
>> "!B64TMP!" echo ICAgYXAoJycpCiAgICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAgICMgIEluc3RhbGwgdGhlIGJ1bmRsZWQgbG9j
>> "!B64TMP!" echo YWwtd2ViLXNlYXJjaCBhZ2VudCBza2lsbCBpbnRvIHRoZSB1c2VyJ3Mgc2tpbGxzCiAgICAjICBk
>> "!B64TMP!" echo aXJlY3RvcnkgKGFkZC9vdmVycmlkZSksIGFuZCByZWNvcmQgdGhlIGluc3RhbGwgcGF0aCBoaW50
>> "!B64TMP!" echo LgogICAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tCiAgICBhcCgnc2F5ICJJbnN0YWxsaW5nIHRoZSBsb2NhbC13ZWIt
>> "!B64TMP!" echo c2VhcmNoIGFnZW50IHNraWxsLi4uIicpCiAgICBhcCgnU0tJTExfRElSPSIkSE9NRS8uYWdlbnRz
>> "!B64TMP!" echo L3NraWxscy9sb2NhbC13ZWItc2VhcmNoIicpCiAgICBhcCgncm0gLXJmICIkU0tJTExfRElSIicp
>> "!B64TMP!" echo CiAgICBhcCgnbWtkaXIgLXAgIiRIT01FLy5hZ2VudHMvc2tpbGxzIicpCiAgICBhcCgnaWYgY3Ag
>> "!B64TMP!" echo LXIgIiRUQVJHRVQvbG9jYWwtd2ViLXNlYXJjaCIgIiRTS0lMTF9ESVIiOyB0aGVuJykKICAgIGFw
>> "!B64TMP!" echo KCcgIHByaW50ZiBcJyVzXFxuXCcgIiRUQVJHRVQiID4gIiRUQVJHRVQvbG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aC9pbnN0YWxsLWRpci50eHQiJykKICAgIGFwKCcgIHByaW50ZiBcJyVzXFxuXCcgIiRUQVJHRVQi
>> "!B64TMP!" echo ID4gIiRTS0lMTF9ESVIvaW5zdGFsbC1kaXIudHh0IicpCiAgICBhcCgnICBzYXkgIiAgQWdlbnQg
>> "!B64TMP!" echo c2tpbGwgaW5zdGFsbGVkOiAkU0tJTExfRElSIicpCiAgICBhcCgnZWxzZScpCiAgICBhcCgnICBz
>> "!B64TMP!" echo YXkgIiAgJHtZRUxMT1d9W1dBUk5JTkddJHtSRVNFVH0gY291bGQgbm90IGNvcHkgdGhlIGxvY2Fs
>> "!B64TMP!" echo LXdlYi1zZWFyY2ggc2tpbGwgdG8gJFNLSUxMX0RJUiInKQogICAgYXAoJ2ZpJykKICAgIGFwKCcn
>> "!B64TMP!" echo KQogICAgIyBJZiB3ZSBsYXVuY2hlZCB0aGUgZW5naW5lIGFib3ZlLCB3YWl0IGZvciBpdCB0byBj
>> "!B64TMP!" echo b21lIG9ubGluZSBub3cgKHRoZQogICAgIyBwcm9tcHRzIGFib3ZlIHJhbiB3aGlsZSBpdCB3YXMg
>> "!B64TMP!" echo Ym9vdGluZyBpbiB0aGUgYmFja2dyb3VuZCkuCiAgICBhcCgnaWYgWyAiJEVOR0lORV9MQVVOQ0hF
>> "!B64TMP!" echo RCIgPSAiMSIgXTsgdGhlbicpCiAgICBhcCgnICBzYXkgIldhaXRpbmcgZm9yIHRoZSBEb2NrZXIg
>> "!B64TMP!" echo ZW5naW5lIHRvIGNvbWUgb25saW5lIC0gdXAgdG8gJHtET0NLRVJfV0FJVF9USU1FT1VUfXMuLi4i
>> "!B64TMP!" echo JykKICAgIGFwKCcgIEREX1dBSVQ9MCcpCiAgICBhcCgnICB3aGlsZSAhIGRvY2tlciBpbmZvID4v
>> "!B64TMP!" echo ZGV2L251bGwgMj4mMTsgZG8nKQogICAgYXAoJyAgICBzbGVlcCA1JykKICAgIGFwKCcgICAgRERf
>> "!B64TMP!" echo V0FJVD0kKChERF9XQUlUICsgNSkpJykKICAgIGFwKCcgICAgaWYgWyAiJEREX1dBSVQiIC1nZSAi
>> "!B64TMP!" echo JERPQ0tFUl9XQUlUX1RJTUVPVVQiIF07IHRoZW4nKQogICAgYXAoJyAgICAgIGVyciAiVGhlIERv
>> "!B64TMP!" echo Y2tlciBlbmdpbmUgZGlkIG5vdCBjb21lIG9ubGluZSB3aXRoaW4gJHtET0NLRVJfV0FJVF9USU1F
>> "!B64TMP!" echo T1VUfXMuIicpCiAgICBhcCgnICAgICAgc2F5ICIgIENoZWNrIERvY2tlciBEZXNrdG9wIG9yOiBz
>> "!B64TMP!" echo dWRvIHN5c3RlbWN0bCBzdGF0dXMgZG9ja2VyIicpCiAgICBhcCgnICAgICAgc2F5ICIgIExpbnV4
>> "!B64TMP!" echo IHBlcm1pc3Npb24gZGVuaWVkIGZyb20gZG9ja2VyIGluZm8/IGFkZCB5b3Vyc2VsZiB0byB0aGUi
>> "!B64TMP!" echo JykKICAgIGFwKCcgICAgICBzYXkgIiAgZG9ja2VyIGdyb3VwOiAgc3VkbyB1c2VybW9kIC1hRyBk
>> "!B64TMP!" echo b2NrZXIgJFVTRVIgIChsb2cgb3V0IGFuZCBiYWNrIGluKSInKQogICAgYXAoJyAgICAgIHNheSAi
>> "!B64TMP!" echo ICB0aGVuIHN0YXJ0IERvY2tlciBhbmQgcmUtcnVuIHRoaXMgaW5zdGFsbGVyLiInKQogICAgYXAo
>> "!B64TMP!" echo JyAgICAgIGV4aXQgMScpCiAgICBhcCgnICAgIGZpJykKICAgIGFwKCcgICAgaWYgWyAkKChERF9X
>> "!B64TMP!" echo QUlUICUgMTUpKSAtZXEgMCBdOyB0aGVuIHNheSAiICAuLi4gc3RpbGwgd2FpdGluZywgJHtERF9X
>> "!B64TMP!" echo QUlUfXMgZWxhcHNlZCI7IGZpJykKICAgIGFwKCcgIGRvbmUnKQogICAgYXAoJyAgb2sgIkRvY2tl
>> "!B64TMP!" echo ciBlbmdpbmUgaXMgb25saW5lIGFmdGVyICR7RERfV0FJVH1zLiInKQogICAgYXAoJ2ZpJykKICAg
>> "!B64TMP!" echo IGFwKCcnKQogICAgIyBQdWxsICsgdXAKICAgIGFwKCdlY2hvJykKICAgIGFwKCdzYXkgIlB1bGxp
>> "!B64TMP!" echo bmcgRG9ja2VyIGltYWdlcyAoZmlyc3QgcnVuIGRvd25sb2FkcyB+My00IEdCLCBwbGVhc2UgYmUg
>> "!B64TMP!" echo cGF0aWVudCkuLi4iJykKICAgIGFwKCdjZCAiJFRBUkdFVCInKQogICAgYXAoJyREQyBwdWxsIHx8
>> "!B64TMP!" echo IHNheSAiJHtZRUxMT1d9W1dBUk5JTkddJHtSRVNFVH0gc29tZSBpbWFnZXMgZmFpbGVkIHRvIHB1
>> "!B64TMP!" echo bGw7IHRyeWluZyB0byBzdGFydCBhbnl3YXkuIicpCiAgICBhcCgnc2F5ICJTdGFydGluZyBzZXJ2
>> "!B64TMP!" echo aWNlcy4uLiInKQogICAgYXAoJ2lmICEgJERDIHVwIC1kOyB0aGVuJykKICAgIGFwKCcgIGVyciAi
>> "!B64TMP!" echo ZG9ja2VyIGNvbXBvc2UgdXAgZmFpbGVkLiBTZWUgbWVzc2FnZXMgYWJvdmUuIicpCiAgICBhcCgn
>> "!B64TMP!" echo ICBzYXkgIiAgQ29tbW9uIGZpeGVzOiInKQogICAgYXAoJyAgc2F5ICIgICAgLSBNYWtlIHN1cmUg
>> "!B64TMP!" echo RG9ja2VyIGlzIHJ1bm5pbmcgKGFuZCB5b3VyIHVzZXIgaXMgaW4gdGhlIFwnZG9ja2VyXCcgZ3Jv
>> "!B64TMP!" echo dXAgb24gTGludXgpLiInKQogICAgYXAoJyAgc2F5ICIgICAgLSBNYWtlIHN1cmUgcG9ydHMgJFNF
>> "!B64TMP!" echo QVJYTkdfUE9SVCBhbmQgJEZJUkVDUkFXTF9QT1JUIGFyZSBub3QgaW4gdXNlLiInKQogICAgYXAo
>> "!B64TMP!" echo JyAgc2F5ICIgICAgLSBSZS1ydW4gdGhpcyBpbnN0YWxsZXIgb3IgcnVuIHVwZGF0ZS5zaCBhZnRl
>> "!B64TMP!" echo ciBmaXhpbmcuIicpCiAgICBhcCgnICBleGl0IDEnKQogICAgYXAoJ2ZpJykKICAgIGFwKCcnKQog
>> "!B64TMP!" echo ICAgIyBEb25lCiAgICBhcCgnZWNobycpCiAgICBhcCgnc2F5ICIke0dSRUVOfT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PSR7UkVTRVR9
>> "!B64TMP!" echo IicpCiAgICBhcCgnc2F5ICIke0dSRUVOfSAgSW5zdGFsbGF0aW9uIGNvbXBsZXRlISR7UkVTRVR9
>> "!B64TMP!" echo IicpCiAgICBhcCgnZWNobycpCiAgICBhcCgnc2F5ICIgIFNlYXJYTkcgIChzZWFyY2ggKyBKU09O
>> "!B64TMP!" echo IEFQSSk6ICBodHRwOi8vbG9jYWxob3N0OiRTRUFSWE5HX1BPUlQiJykKICAgIGFwKCdzYXkgIiAg
>> "!B64TMP!" echo RmlyZWNyYXdsIChzY3JhcGUvY3Jhd2wgQVBJKTogaHR0cDovL2xvY2FsaG9zdDokRklSRUNSQVdM
>> "!B64TMP!" echo X1BPUlQiJykKICAgIGFwKCdzYXkgIiAgbG9jYWwtd2ViLXNlYXJjaCBza2lsbDogICAgICAgICAg
>> "!B64TMP!" echo ICAgICRIT01FLy5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2giJykKICAgIGFwKCdlY2hv
>> "!B64TMP!" echo JykKICAgIGFwKCdzYXkgIiAgSWYgeW91ciBhZ2VudCB3YXMgYWxyZWFkeSBydW5uaW5nLCByZXN0
>> "!B64TMP!" echo YXJ0IGl0IHNvIGl0IHBpY2tzIHVwIicpCiAgICBhcCgnc2F5ICIgIHRoZSBuZXcgc2tpbGwuIicp
>> "!B64TMP!" echo CiAgICBhcCgnZWNobycpCiAgICBhcCgnc2F5ICIgIE1hbmFnZSB0aGUgc3RhY2sgd2l0aCB0aGUg
>> "!B64TMP!" echo c2NyaXB0cyBpbjoiJykKICAgIGFwKCdzYXkgIiAgICAkVEFSR0VUIicpCiAgICBhcCgnc2F5ICIg
>> "!B64TMP!" echo ICAgICAuL3J1bi5zaCAgIC4vc3RvcC5zaCAgIC4vdXBkYXRlLnNoICAgLi91bmluc3RhbGwuc2gi
>> "!B64TMP!" echo JykKICAgIGFwKCdlY2hvJykKICAgIGFwKCdzYXkgIiAgU2VlIFJFQURNRS5tZCBmb3IgaG93IHRv
>> "!B64TMP!" echo IGNvbm5lY3QgdGhpcyB0byB5b3VyIEFJIG1vZGVscyInKQogICAgYXAoJ3NheSAiICAobG9jYWwt
>> "!B64TMP!" echo d2ViLXNlYXJjaCBza2lsbCwgTE0gU3R1ZGlvLCBNQ1Agc2VydmVyLCBkaXJlY3QgcHJvbXB0aW5n
>> "!B64TMP!" echo LCBldGMuKS4iJykKICAgIGFwKCdzYXkgIiR7R1JFRU59PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JHtSRVNFVH0iJykKCiAgICByZXR1
>> "!B64TMP!" echo cm4gIlxuIi5qb2luKG91dCkgKyAiXG4iCgoKZGVmIG1haW4oKToKICAgICMgSU1QT1JUQU5UOiB3
>> "!B64TMP!" echo cml0ZSB0aGUgLmJhdCB0byBkaXNrIEZJUlNULCBUSEVOIGdlbmVyYXRlIHRoZSAuc2guCiAgICAj
>> "!B64TMP!" echo IFRoZSAuc2ggZW1iZWRzIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCBhcyBhIGhlcmVkb2MsIHNv
>> "!B64TMP!" echo IGl0IG11c3QgcmVhZAogICAgIyB0aGUgZnJlc2hseS13cml0dGVuIC5iYXQgKG5vdCBhIHN0YWxl
>> "!B64TMP!" echo IHByZXZpb3VzLWdlbmVyYXRpb24gY29weSkuCiAgICBiYXQgPSBnZW5fYmF0KCkKICAgIHdpdGgg
>> "!B64TMP!" echo b3Blbihvcy5wYXRoLmpvaW4oU1JDLCAiaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IiksICJ3YiIp
>> "!B64TMP!" echo IGFzIGY6CiAgICAgICAgZi53cml0ZShiYXQuZW5jb2RlKCJ1dGYtOCIpKQogICAgc2ggPSBnZW5f
>> "!B64TMP!" echo c2goKQogICAgd2l0aCBvcGVuKG9zLnBhdGguam9pbihTUkMsICJpbnN0YWxsLWxvY2FsLXNlYXJj
>> "!B64TMP!" echo aC5zaCIpLCAid2IiKSBhcyBmOgogICAgICAgIGYud3JpdGUoc2guZW5jb2RlKCJ1dGYtOCIpKQog
>> "!B64TMP!" echo ICAgb3MuY2htb2Qob3MucGF0aC5qb2luKFNSQywgImluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIiks
>> "!B64TMP!" echo IDBvNzU1KQogICAgcHJpbnQoIldyb3RlIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCAoJWQgYnl0
>> "!B64TMP!" echo ZXMpIiAlIGxlbihiYXQpKQogICAgcHJpbnQoIldyb3RlIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNo
>> "!B64TMP!" echo ICAoJWQgYnl0ZXMpIiAlIGxlbihzaCkpCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAg
>> "!B64TMP!" echo IG1haW4oKQo=
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
>> "!B64TMP!" echo dWxsIGxvY2FsLXNlYXJjaCBzb3VyY2UgdHJlZSAoNDUgZmlsZXM7IHRoZSBnZW5lcmF0ZWQgaW5z
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
>> "!B64TMP!" echo Yl9zY3JhcGUucHkiLAogICAgIyAtLS0tIFlvdVR1YmUgdHJhbnNjcmlwdHM6IGEgZnJlZSB0b29s
>> "!B64TMP!" echo LCBidXQgbm90IHBhcnQgb2YgdGhlIEZpcmVjcmF3bAogICAgIyBNQ1Agc3VyZmFjZSAodGFsa3Mg
>> "!B64TMP!" echo dG8gWW91VHViZSBkaXJlY3RseSwgbm8gbG9jYWwgc3RhY2sgaW52b2x2ZWQpIC0tLS0KICAgICJs
>> "!B64TMP!" echo b2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weSIsCiAgICAj
>> "!B64TMP!" echo IC0tLS0gdGhlIDI0IEZpcmVjcmF3bCBNQ1AtZXF1aXZhbGVudCB0b29scyAod2ViX3NlYXJjaC93
>> "!B64TMP!" echo ZWJfc2NyYXBlIGFib3ZlICsgdGhlc2UgMjIpIC0tLS0KICAgICJsb2NhbC13ZWItc2VhcmNoL3Nj
>> "!B64TMP!" echo cmlwdHMvd2ViX21hcC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9jcmF3
>> "!B64TMP!" echo bC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9jcmF3bF9zdGF0dXMucHki
>> "!B64TMP!" echo LAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfYWdlbnQucHkiLAogICAgImxvY2Fs
>> "!B64TMP!" echo LXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfYWdlbnRfc3RhdHVzLnB5IiwKICAgICJsb2NhbC13ZWIt
>> "!B64TMP!" echo c2VhcmNoL3NjcmlwdHMvd2ViX2ludGVyYWN0LnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3Nj
>> "!B64TMP!" echo cmlwdHMvd2ViX2ludGVyYWN0X3N0b3AucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfcGFyc2UucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRv
>> "!B64TMP!" echo cl9jcmVhdGUucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9s
>> "!B64TMP!" echo aXN0LnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfZ2V0LnB5
>> "!B64TMP!" echo IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfdXBkYXRlLnB5IiwK
>> "!B64TMP!" echo ICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfZGVsZXRlLnB5IiwKICAg
>> "!B64TMP!" echo ICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfcnVuLnB5IiwKICAgICJsb2Nh
>> "!B64TMP!" echo bC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfY2hlY2tzLnB5IiwKICAgICJsb2NhbC13
>> "!B64TMP!" echo ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfY2hlY2sucHkiLAogICAgImxvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfc2VhcmNoLnB5IiwKICAgICJsb2NhbC13ZWItc2Vh
>> "!B64TMP!" echo cmNoL3NjcmlwdHMvd2ViX3Jlc2VhcmNoX2luc3BlY3QucHkiLAogICAgImxvY2FsLXdlYi1zZWFy
>> "!B64TMP!" echo Y2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfcmVsYXRlZC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aC9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWFkLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3Nj
>> "!B64TMP!" echo cmlwdHMvd2ViX2dpdGh1Yl9zZWFyY2gucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSIsCl0KCk5fRklMRVMgPSBsZW4oU09VUkNFX0ZJTEVT
>> "!B64TMP!" echo KSArIGxlbihSSUdfRklMRVMpCgoKZGVmIHJlYWRfcm9vdChyZWwpOgogICAgd2l0aCBvcGVuKG9z
>> "!B64TMP!" echo LnBhdGguam9pbihST09ULCByZWwpLCAicmIiKSBhcyBmOgogICAgICAgIHJldHVybiBmLnJlYWQo
>> "!B64TMP!" echo KQoKCmRlZiByZWFkX3NyYyhyZWwpOgogICAgd2l0aCBvcGVuKG9zLnBhdGguam9pbihTUkMsIHJl
>> "!B64TMP!" echo bCksICJyYiIpIGFzIGY6CiAgICAgICAgcmV0dXJuIGYucmVhZCgpCgoKZGVmIGI2NF9jaHVua2Vk
>> "!B64TMP!" echo KGRhdGEsIHdpZHRoPTc2KToKICAgIHMgPSBiYXNlNjQuYjY0ZW5jb2RlKGRhdGEpLmRlY29kZSgi
>> "!B64TMP!" echo YXNjaWkiKQogICAgcmV0dXJuIFtzW2k6aSArIHdpZHRoXSBmb3IgaSBpbiByYW5nZSgwLCBsZW4o
>> "!B64TMP!" echo cyksIHdpZHRoKV0KCgpkZWYgdGFnX2ZvcihyZWwpOgogICAgcmV0dXJuICJFT0ZfIiArICIiLmpv
>> "!B64TMP!" echo aW4oYyBpZiBjLmlzYWxudW0oKSBlbHNlICJfIiBmb3IgYyBpbiByZWwpLnVwcGVyKCkKCgojID09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09CiMgIFdpbmRvd3MgcGFja2VyICguYmF0KQojID09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09CgpkZWYgZ2VuX2JhdF9wYWNrZXIoKToKICAgIG91dCA9IFtdCiAgICBhcCA9IG91
>> "!B64TMP!" echo dC5hcHBlbmQKCiAgICBhcCgnQGVjaG8gb2ZmJykKICAgIGFwKCdzZXRsb2NhbCBlbmFibGVEZWxh
>> "!B64TMP!" echo eWVkRXhwYW5zaW9uJykKICAgIGFwKCdjaGNwIDY1MDAxID5udWwnKQogICAgYXAoJ3RpdGxlIExv
>> "!B64TMP!" echo Y2FsIFNlYXJjaCBEZXYgUmlnIC0gVW5wYWNrJykKICAgIGFwKCcnKQogICAgYXAoJ1JFTSA9PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT0nKQogICAgYXAoJ1JFTSAgTG9jYWwgU2VhcmNoIERFViBSSUcgcGFja2Vy
>> "!B64TMP!" echo ICAtICBXaW5kb3dzJykKICAgIGFwKCdSRU0gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCdS
>> "!B64TMP!" echo RU0gIFNlbGYtY29udGFpbmVkOiBlbWJlZHMgdGhlIGNvbXBsZXRlIGJ1aWxkL3Rlc3QgZW52aXJv
>> "!B64TMP!" echo bm1lbnQgZm9yIHRoZScpCiAgICBhcCgnUkVNICBsb2NhbC1zZWFyY2ggaW5zdGFsbGVyczonKQog
>> "!B64TMP!" echo ICAgYXAoJ1JFTSAgICAqIHRoZSBsb2NhbC1zZWFyY2ggc291cmNlIHRyZWUgKCVkIGZpbGVzKScg
>> "!B64TMP!" echo JSBsZW4oU09VUkNFX0ZJTEVTKSkKICAgIGFwKCdSRU0gICAgKiBnZW5faW5zdGFsbGVycy5weSAv
>> "!B64TMP!" echo IGdlbl9yaWcucHkgKHRoZSB0d28gZ2VuZXJhdG9ycyknKQogICAgYXAoJ1JFTSAgICAqIGV2ZXJ5
>> "!B64TMP!" echo IHRlc3QgKyBidWlsZCBzY3JpcHQgKyBCVUlMRC5tZCcpCiAgICBhcCgnUkVNICBVbnBhY2sgYW55
>> "!B64TMP!" echo d2hlcmUsIHRoZW4gcnVuIGJ1aWxkLmJhdCAob3I6IHB5dGhvbiBnZW5faW5zdGFsbGVycy5weSkg
>> "!B64TMP!" echo dG8nKQogICAgYXAoJ1JFTSAgcmVnZW5lcmF0ZSB0aGUgaW5zdGFsbGVycywgYW5kOiBweXRob24g
>> "!B64TMP!" echo Z2VuX3JpZy5weSB0byByZWdlbmVyYXRlIHRoZXNlJykKICAgIGFwKCdSRU0gIHBhY2tlcnMgYnl0
>> "!B64TMP!" echo ZS1mb3ItYnl0ZS4nKQogICAgYXAoJ1JFTSA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJycp
>> "!B64TMP!" echo CiAgICBhcCgnZWNobyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT0nKQogICAgYXAoJ2VjaG8gICBMb2NhbCBTZWFyY2ggREVWIFJJRyAg
>> "!B64TMP!" echo KGJ1aWxkICsgdGVzdCBlbnZpcm9ubWVudCknKQogICAgYXAoJ2VjaG8gICBVbnBhY2tzIGV2ZXJ5
>> "!B64TMP!" echo dGhpbmcgbmVlZGVkIHRvIHJlZ2VuZXJhdGUgYW5kIHZlcmlmeSB0aGUnKQogICAgYXAoJ2VjaG8g
>> "!B64TMP!" echo ICBpbnN0YWxsLWxvY2FsLXNlYXJjaCBpbnN0YWxsZXJzLicpCiAgICBhcCgnZWNobyA9PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQog
>> "!B64TMP!" echo ICAgYXAoJ2VjaG8uJykKICAgIGFwKCcnKQogICAgIyBQcm9tcHRzCiAgICBhcCgnc2V0ICJERUZB
>> "!B64TMP!" echo VUxUX1RBUkdFVD0lfmRwMGxvY2FsLXNlYXJjaC1kZXYiJykKICAgIGFwKCcnKQogICAgYXAoJ2Vj
>> "!B64TMP!" echo aG8gLS0tIFN0ZXAgMSBvZiAzOiBVbnBhY2sgbG9jYXRpb24gLS0tLS0tLS0tLS0tLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tJykKICAgIGFwKCdlY2hvICAgRGVmYXVsdDogJURFRkFVTFRfVEFSR0VUJScpCiAgICBh
>> "!B64TMP!" echo cCgnc2V0ICJUQVJHRVQ9IicpCiAgICBhcCgnc2V0IC9wIFRBUkdFVD0iICBUYXJnZXQgZm9sZGVy
>> "!B64TMP!" echo IFtwcmVzcyBFbnRlciBmb3IgZGVmYXVsdF06ICInKQogICAgYXAoJ2lmICIhVEFSR0VUISI9PSIi
>> "!B64TMP!" echo IHNldCAiVEFSR0VUPSVERUZBVUxUX1RBUkdFVCUiJykKICAgIGFwKCdzZXQgIlRBUkdFVD0hVEFS
>> "!B64TMP!" echo R0VUOiI9ISInKQogICAgYXAoJ2ZvciAlJUkgaW4gKCIhVEFSR0VUISIpIGRvIHNldCAiVEFSR0VU
>> "!B64TMP!" echo PSUlfmZJIicpCiAgICBhcCgnZWNobyAgIFVzaW5nOiAhVEFSR0VUIScpCiAgICBhcCgnZWNobyAg
>> "!B64TMP!" echo IF4oZXhpc3RpbmcgZmlsZXMgaW4gdGhlIHRhcmdldCBmb2xkZXIgYXJlIG92ZXJ3cml0dGVuXikn
>> "!B64TMP!" echo KQogICAgYXAoJ2VjaG8uJykKICAgIGFwKCcnKQogICAgYXAoJ2VjaG8gLS0tIFN0ZXAgMiBvZiAz
>> "!B64TMP!" echo OiBCdWlsZCBub3c/IC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tJykKICAgIGFwKCdl
>> "!B64TMP!" echo Y2hvICAgR2VuZXJhdGUgaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0Ly5zaCB3aXRoIFB5dGhvbiBy
>> "!B64TMP!" echo aWdodCBhZnRlciB1bnBhY2tpbmc/JykKICAgIGFwKCdzZXQgIkJVSUxETk9XPSInKQogICAgYXAo
>> "!B64TMP!" echo J3NldCAvcCBCVUlMRE5PVz0iICBSdW4gdGhlIGluc3RhbGxlciBidWlsZCBub3c/IFtZL25dOiAi
>> "!B64TMP!" echo JykKICAgIGFwKCdlY2hvLicpCiAgICBhcCgnJykKICAgIGFwKCdlY2hvIC0tLSBTdGVwIDMgb2Yg
>> "!B64TMP!" echo MzogQ29uZmlybSAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLScpCiAgICBhcCgn
>> "!B64TMP!" echo ZWNobyAgIFdpbGwgdW5wYWNrICVkIGZpbGVzIGludG86ICFUQVJHRVQhJyAlIE5fRklMRVMpCiAg
>> "!B64TMP!" echo ICBhcCgnc2V0ICJDT05GSVJNPSInKQogICAgYXAoJ3NldCAvcCBDT05GSVJNPSJQcm9jZWVkPyBb
>> "!B64TMP!" echo WS9uXTogIicpCiAgICBhcCgnaWYgL2kgIiFDT05GSVJNISI9PSJuIiAoIGVjaG8gQ2FuY2VsbGVk
>> "!B64TMP!" echo LiAmIHBhdXNlICYgZXhpdCAvYiAwICknKQogICAgYXAoJycpCiAgICAjIEZvbGRlcnMKICAgIGFw
>> "!B64TMP!" echo KCdpZiBub3QgZXhpc3QgIiFUQVJHRVQhIiBta2RpciAiIVRBUkdFVCEiJykKICAgIGFwKCdpZiBu
>> "!B64TMP!" echo b3QgZXhpc3QgIiFUQVJHRVQhXFxsb2NhbC1zZWFyY2giIG1rZGlyICIhVEFSR0VUIVxcbG9jYWwt
>> "!B64TMP!" echo c2VhcmNoIicpCiAgICBhcCgnaWYgbm90IGV4aXN0ICIhVEFSR0VUIVxcbG9jYWwtc2VhcmNoXFxj
>> "!B64TMP!" echo b25maWdcXHNlYXJ4bmciIG1rZGlyICIhVEFSR0VUIVxcbG9jYWwtc2VhcmNoXFxjb25maWdcXHNl
>> "!B64TMP!" echo YXJ4bmciJykKICAgIGFwKCdpZiBub3QgZXhpc3QgIiFUQVJHRVQhXFxsb2NhbC1zZWFyY2hcXGxv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2hcXHNjcmlwdHMiIG1rZGlyICIhVEFSR0VUIVxcbG9jYWwtc2VhcmNoXFxs
>> "!B64TMP!" echo b2NhbC13ZWItc2VhcmNoXFxzY3JpcHRzIicpCiAgICBhcCgnJykKICAgIGFwKCdlY2hvIFVucGFj
>> "!B64TMP!" echo a2luZyBmaWxlcy4uLicpCgogICAgZGVmIGI2NF9ibG9jayhsYWJlbCwgZGF0YSwgb3V0X3dpbik6
>> "!B64TMP!" echo CiAgICAgICAgbGluZXMgPSBiNjRfY2h1bmtlZChkYXRhKQogICAgICAgIHRhZyA9ICJMU1IiICsg
>> "!B64TMP!" echo c3RyKHpsaWIuY3JjMzIobGFiZWwuZW5jb2RlKCJ1dGYtOCIpKSAmIDB4RkZGRkZGRkYpCiAgICAg
>> "!B64TMP!" echo ICAgYXAoJycpCiAgICAgICAgYXAoJ1JFTSAtLS0gJyArIGxhYmVsICsgJyAtLS0nKQogICAgICAg
>> "!B64TMP!" echo IGFwKCdzZXQgIkI2NFRNUD0lVEVNUCVcXCcgKyB0YWcgKyAnLmI2NCInKQogICAgICAgIGZpcnN0
>> "!B64TMP!" echo ID0gVHJ1ZQogICAgICAgIGZvciBsbiBpbiBsaW5lczoKICAgICAgICAgICAgYXAoKCc+ICcgaWYg
>> "!B64TMP!" echo Zmlyc3QgZWxzZSAnPj4gJykgKyAnIiFCNjRUTVAhIiBlY2hvICcgKyBsbikKICAgICAgICAgICAg
>> "!B64TMP!" echo Zmlyc3QgPSBGYWxzZQogICAgICAgIGFwKCdzZXQgIkxTX0I2NF9JTj0hQjY0VE1QISInKQogICAg
>> "!B64TMP!" echo ICAgIGFwKCdzZXQgIkxTX0I2NF9PVVQ9JyArIG91dF93aW4gKyAnIicpCiAgICAgICAgYXAoJ2Nh
>> "!B64TMP!" echo bGwgOmRlY29kZV9iNjQnKQogICAgICAgIGFwKCdkZWwgL1EgIiFCNjRUTVAhIiA+bnVsIDI+JjEn
>> "!B64TMP!" echo KQoKICAgICMgbG9jYWwtc2VhcmNoIHNvdXJjZXMKICAgIGZvciByZWwgaW4gU09VUkNFX0ZJTEVT
>> "!B64TMP!" echo OgogICAgICAgIGxhYmVsID0gImxvY2FsLXNlYXJjaC8iICsgcmVsCiAgICAgICAgYjY0X2Jsb2Nr
>> "!B64TMP!" echo KGxhYmVsLCByZWFkX3NyYyhyZWwpLCAnIVRBUkdFVCFcXGxvY2FsLXNlYXJjaFxcJyArIHJlbC5y
>> "!B64TMP!" echo ZXBsYWNlKCIvIiwgIlxcIikpCiAgICAjIHJpZyBmaWxlcwogICAgZm9yIHJlbCBpbiBSSUdfRklM
>> "!B64TMP!" echo RVM6CiAgICAgICAgYjY0X2Jsb2NrKHJlbCwgcmVhZF9yb290KHJlbCksICchVEFSR0VUIVxcJyAr
>> "!B64TMP!" echo IHJlbC5yZXBsYWNlKCIvIiwgIlxcIikpCgogICAgYXAoJycpCiAgICBhcCgnUkVNIEtlZXAgYSBj
>> "!B64TMP!" echo b3B5IG9mIHRoaXMgcGFja2VyIGluIHRoZSB0YXJnZXQgc28gdGhlIHJpZyBpcyBjb21wbGV0ZS4n
>> "!B64TMP!" echo KQogICAgYXAoJ2NvcHkgL1kgIiV+ZjAiICIhVEFSR0VUIVxcbG9jYWwtc2VhcmNoLXJpZy5iYXQi
>> "!B64TMP!" echo ID5udWwgMj4mMScpCiAgICBhcCgnZWNobyAgIERvbmUgLSAlZCBmaWxlcyArIHRoaXMgcGFja2Vy
>> "!B64TMP!" echo LicgJSBOX0ZJTEVTKQogICAgYXAoJycpCiAgICAjIE9wdGlvbmFsIGJ1aWxkCiAgICBhcCgnaWYg
>> "!B64TMP!" echo L2kgbm90ICIhQlVJTEROT1chIj09Im4iICgnKQogICAgYXAoJyAgc2V0ICJQWT0iJykKICAgIGFw
>> "!B64TMP!" echo KCcgIHB5IC0zIC1jICJwcmludCgxKSIgPm51bCAyPiYxJykKICAgIGFwKCcgIGlmIG5vdCBlcnJv
>> "!B64TMP!" echo cmxldmVsIDEgc2V0ICJQWT1weSAtMyInKQogICAgYXAoJyAgaWYgbm90IGRlZmluZWQgUFkgKCcp
>> "!B64TMP!" echo CiAgICBhcCgnICAgIHB5dGhvbiAtYyAicHJpbnQoMSkiID5udWwgMj4mMScpCiAgICBhcCgnICAg
>> "!B64TMP!" echo IGlmIG5vdCBlcnJvcmxldmVsIDEgc2V0ICJQWT1weXRob24iJykKICAgIGFwKCcgICknKQogICAg
>> "!B64TMP!" echo YXAoJyAgaWYgbm90IGRlZmluZWQgUFkgKCcpCiAgICBhcCgnICAgIHB5dGhvbjMgLWMgInByaW50
>> "!B64TMP!" echo KDEpIiA+bnVsIDI+JjEnKQogICAgYXAoJyAgICBpZiBub3QgZXJyb3JsZXZlbCAxIHNldCAiUFk9
>> "!B64TMP!" echo cHl0aG9uMyInKQogICAgYXAoJyAgKScpCiAgICBhcCgnICBpZiBub3QgZGVmaW5lZCBQWSAoJykK
>> "!B64TMP!" echo ICAgIGFwKCcgICAgZWNoby4nKQogICAgYXAoJyAgICBlY2hvICAgW1dBUk5JTkddIFB5dGhvbiBu
>> "!B64TMP!" echo b3QgZm91bmQgLSBza2lwcGluZyB0aGUgYnVpbGQuJykKICAgIGFwKCcgICAgZWNobyAgIEluc3Rh
>> "!B64TMP!" echo bGwgUHl0aG9uIDMuOCssIHRoZW4gcnVuIGJ1aWxkLmJhdCBpbiB0aGUgdGFyZ2V0IGZvbGRlci4n
>> "!B64TMP!" echo KQogICAgYXAoJyAgKSBlbHNlICgnKQogICAgYXAoJyAgICBlY2hvLicpCiAgICBhcCgnICAgIGVj
>> "!B64TMP!" echo aG8gQnVpbGRpbmcgaW5zdGFsbGVycyB3aXRoICFQWSEgLi4uJykKICAgIGFwKCcgICAgcHVzaGQg
>> "!B64TMP!" echo IiFUQVJHRVQhIicpCiAgICBhcCgnICAgICFQWSEgZ2VuX2luc3RhbGxlcnMucHknKQogICAgYXAo
>> "!B64TMP!" echo JyAgICBpZiBlcnJvcmxldmVsIDEgKCcpCiAgICBhcCgnICAgICAgcG9wZCcpCiAgICBhcCgnICAg
>> "!B64TMP!" echo ICAgZWNobyAgIFtFUlJPUl0gZ2VuX2luc3RhbGxlcnMucHkgZmFpbGVkLicpCiAgICBhcCgnICAg
>> "!B64TMP!" echo ICAgcGF1c2UnKQogICAgYXAoJyAgICAgIGV4aXQgL2IgMScpCiAgICBhcCgnICAgICknKQogICAg
>> "!B64TMP!" echo YXAoJyAgICBwb3BkJykKICAgIGFwKCcgICAgZWNobyAgIEluc3RhbGxlcnMgd3JpdHRlbiB0byAh
>> "!B64TMP!" echo VEFSR0VUIVxcbG9jYWwtc2VhcmNoXFwnKQogICAgYXAoJyAgKScpCiAgICBhcCgnKScpCiAgICBh
>> "!B64TMP!" echo cCgnJykKICAgICMgRG9uZQogICAgYXAoJ2VjaG8uJykKICAgIGFwKCdlY2hvID09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PScpCiAgICBh
>> "!B64TMP!" echo cCgnZWNobyAgIERldiByaWcgcmVhZHk6ICFUQVJHRVQhJykKICAgIGFwKCdlY2hvLicpCiAgICBh
>> "!B64TMP!" echo cCgnZWNobyAgIE5leHQgc3RlcHMgXihzZWUgQlVJTEQubWQgaW5zaWRlXik6JykKICAgIGFwKCdl
>> "!B64TMP!" echo Y2hvICAgICBidWlsZC5iYXQgICAgICAgICAgICAgICAgICAgICByZWJ1aWxkIGluc3RhbGxlcnMg
>> "!B64TMP!" echo KyBwYWNrZXJzICsgdGVzdHMnKQogICAgYXAoJ2VjaG8gICAgIHB5dGhvbiBnZW5faW5zdGFsbGVy
>> "!B64TMP!" echo cy5weSAgICAgIHJlYnVpbGQganVzdCB0aGUgaW5zdGFsbGVycycpCiAgICBhcCgnZWNobyAgICAg
>> "!B64TMP!" echo cHl0aG9uIGdlbl9yaWcucHkgICAgICAgICAgICAgcmVidWlsZCB0aGVzZSBwYWNrZXJzJykKICAg
>> "!B64TMP!" echo IGFwKCdlY2hvID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PScpCiAgICBhcCgnZWNoby4nKQogICAgYXAoJ3BhdXNlJykKICAgIGFwKCdl
>> "!B64TMP!" echo eGl0IC9iIDAnKQogICAgYXAoJycpCiAgICBhcCgnOmRlY29kZV9iNjQnKQogICAgYXAoJ1JFTSAg
>> "!B64TMP!" echo JWVudjpMU19CNjRfSU4lID0gLmI2NCB0ZW1wIGZpbGUsICVlbnY6TFNfQjY0X09VVCUgPSBvdXRw
>> "!B64TMP!" echo dXQgcGF0aCcpCiAgICBhcCgncG93ZXJzaGVsbCAtTm9Qcm9maWxlIC1Db21tYW5kICIkaW49JGVu
>> "!B64TMP!" echo djpMU19CNjRfSU47ICRvdXQ9JGVudjpMU19CNjRfT1VUOyBbSU8uRmlsZV06OldyaXRlQWxsQnl0
>> "!B64TMP!" echo ZXMoJG91dCwgW0NvbnZlcnRdOjpGcm9tQmFzZTY0U3RyaW5nKCgoR2V0LUNvbnRlbnQgLVJhdyAk
>> "!B64TMP!" echo aW4pIC1yZXBsYWNlIFwnXFxzXCcsXCdcJykpKSInKQogICAgYXAoJ2V4aXQgL2IgMCcpCgogICAg
>> "!B64TMP!" echo cmV0dXJuICJcclxuIi5qb2luKG91dCkgKyAiXHJcbiIKCgojID09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo CiMgIExpbnV4IC8gbWFjT1MgcGFja2VyICguc2gpCiMgPT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KCmRl
>> "!B64TMP!" echo ZiBnZW5fc2hfcGFja2VyKCk6CiAgICBvdXQgPSBbXQogICAgYXAgPSBvdXQuYXBwZW5kCgogICAg
>> "!B64TMP!" echo YXAoJyMhL3Vzci9iaW4vZW52IGJhc2gnKQogICAgYXAoJyMgPT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0n
>> "!B64TMP!" echo KQogICAgYXAoJyMgIExvY2FsIFNlYXJjaCBERVYgUklHIHBhY2tlciAgLSAgTGludXggLyBtYWNP
>> "!B64TMP!" echo UyAvIEdpdCBCYXNoJykKICAgIGFwKCcjID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAgIGFwKCcj
>> "!B64TMP!" echo ICBTZWxmLWNvbnRhaW5lZDogZW1iZWRzIHRoZSBjb21wbGV0ZSBidWlsZC90ZXN0IGVudmlyb25t
>> "!B64TMP!" echo ZW50IGZvciB0aGUnKQogICAgYXAoJyMgIGxvY2FsLXNlYXJjaCBpbnN0YWxsZXJzOicpCiAgICBh
>> "!B64TMP!" echo cCgnIyAgICAqIHRoZSBsb2NhbC1zZWFyY2ggc291cmNlIHRyZWUgKCVkIGZpbGVzKScgJSBsZW4o
>> "!B64TMP!" echo U09VUkNFX0ZJTEVTKSkKICAgIGFwKCcjICAgICogZ2VuX2luc3RhbGxlcnMucHkgLyBnZW5fcmln
>> "!B64TMP!" echo LnB5ICh0aGUgdHdvIGdlbmVyYXRvcnMpJykKICAgIGFwKCcjICAgICogZXZlcnkgdGVzdCArIGJ1
>> "!B64TMP!" echo aWxkIHNjcmlwdCArIEJVSUxELm1kJykKICAgIGFwKCcjICAgICogdGhlIFdpbmRvd3MgcGFja2Vy
>> "!B64TMP!" echo IChsb2NhbC1zZWFyY2gtcmlnLmJhdCknKQogICAgYXAoJyMgIFNvIHRoaXMgT05FIGZpbGUgcmVw
>> "!B64TMP!" echo cm9kdWNlcyB0aGUgd2hvbGUgcmlnIGFueXdoZXJlLCBpbmNsdWRpbmcgYm90aCcpCiAgICBhcCgn
>> "!B64TMP!" echo IyAgcGFja2Vycy4gVGhlIGluc3RhbGxlcnMgdGhlbXNlbHZlcyBhcmUgZ2VuZXJhdGVkIGFmdGVy
>> "!B64TMP!" echo IHVucGFja2luZycpCiAgICBhcCgnIyAgKHRoaXMgc2NyaXB0IG9mZmVycyB0byBkbyBpdCkgd2l0
>> "!B64TMP!" echo aCBnZW5faW5zdGFsbGVycy5weS4nKQogICAgYXAoJyMgPT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0nKQog
>> "!B64TMP!" echo ICAgYXAoJycpCiAgICBhcCgnc2V0IC11JykKICAgIGFwKCcnKQogICAgYXAoJ0JPTEQ9IlxcMDMz
>> "!B64TMP!" echo WzFtIjsgR1JFRU49IlxcMDMzWzMybSI7IFlFTExPVz0iXFwwMzNbMzNtIjsgUkVEPSJcXDAzM1sz
>> "!B64TMP!" echo MW0iOyBDWUFOPSJcXDAzM1szNm0iOyBSRVNFVD0iXFwwMzNbMG0iJykKICAgIGFwKCdzYXkoKSAg
>> "!B64TMP!" echo eyBwcmludGYgIiViXFxuIiAiJDEiOyB9JykKICAgIGFwKCdlcnIoKSAgeyBwcmludGYgIiViW0VS
>> "!B64TMP!" echo Uk9SXSViICVzXFxuIiAiJFJFRCIgIiRSRVNFVCIgIiQxIiA+JjI7IH0nKQogICAgYXAoJ29rKCkg
>> "!B64TMP!" echo ICB7IHByaW50ZiAiJWJbT0tdJWIgJXNcXG4iICIkR1JFRU4iICIkUkVTRVQiICIkMSI7IH0nKQog
>> "!B64TMP!" echo ICAgYXAoJ2hkcigpICB7IHByaW50ZiAiXFxuJWItLS0gJXMgLS0tJWJcXG4iICIkQ1lBTiIgIiQx
>> "!B64TMP!" echo IiAiJFJFU0VUIjsgfScpCiAgICBhcCgnbG93ZXIoKSB7IHByaW50ZiBcJyVzXCcgIiQxIiB8IHRy
>> "!B64TMP!" echo IFwnWzp1cHBlcjpdXCcgXCdbOmxvd2VyOl1cJzsgfSAgIyBiYXNoLTMuMiAobWFjT1MpIHNhZmUn
>> "!B64TMP!" echo KQogICAgYXAoJycpCiAgICBhcCgnY2F0IDw8XCdCQU5ORVJcJycpCiAgICBhcCgnPT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09JykKICAg
>> "!B64TMP!" echo IGFwKCcgIExvY2FsIFNlYXJjaCBERVYgUklHICAoYnVpbGQgKyB0ZXN0IGVudmlyb25tZW50KScp
>> "!B64TMP!" echo CiAgICBhcCgnICBVbnBhY2tzIGV2ZXJ5dGhpbmcgbmVlZGVkIHRvIHJlZ2VuZXJhdGUgYW5kIHZl
>> "!B64TMP!" echo cmlmeSB0aGUnKQogICAgYXAoJyAgaW5zdGFsbC1sb2NhbC1zZWFyY2ggaW5zdGFsbGVycy4nKQog
>> "!B64TMP!" echo ICAgYXAoJz09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PScpCiAgICBhcCgnQkFOTkVSJykKICAgIGFwKCcnKQogICAgYXAoJ1NDUklQVF9E
>> "!B64TMP!" echo SVI9IiQoY2QgIiQoZGlybmFtZSAiJDAiKSIgJiYgcHdkKSInKQogICAgYXAoJ0RFRkFVTFRfVEFS
>> "!B64TMP!" echo R0VUPSIkU0NSSVBUX0RJUi9sb2NhbC1zZWFyY2gtZGV2IicpCiAgICBhcCgnJykKICAgIGFwKCdo
>> "!B64TMP!" echo ZHIgIlN0ZXAgMSBvZiAzOiBVbnBhY2sgbG9jYXRpb24iJykKICAgIGFwKCdzYXkgIiAgRGVmYXVs
>> "!B64TMP!" echo dDogJERFRkFVTFRfVEFSR0VUIicpCiAgICBhcCgncHJpbnRmICIgIFRhcmdldCBmb2xkZXIgW3By
>> "!B64TMP!" echo ZXNzIEVudGVyIGZvciBkZWZhdWx0XTogIicpCiAgICBhcCgncmVhZCAtciBUQVJHRVQnKQogICAg
>> "!B64TMP!" echo YXAoJ1sgLXogIiRUQVJHRVQiIF0gJiYgVEFSR0VUPSIkREVGQVVMVF9UQVJHRVQiJykKICAgIGFw
>> "!B64TMP!" echo KCdpZiBbICIke1RBUkdFVCNcXH59IiAhPSAiJFRBUkdFVCIgXTsgdGhlbiBUQVJHRVQ9IiRIT01F
>> "!B64TMP!" echo JHtUQVJHRVQjXFx+fSI7IGZpICAjIFBPU0lYIHRpbGRlIGV4cGFuc2lvbicpCiAgICBhcCgnbWtk
>> "!B64TMP!" echo aXIgLXAgIiRUQVJHRVQiJykKICAgIGFwKCdUQVJHRVQ9IiQoY2QgIiRUQVJHRVQiICYmIHB3ZCki
>> "!B64TMP!" echo JykKICAgIGFwKCdzYXkgIiAgVXNpbmc6ICRUQVJHRVQiJykKICAgIGFwKCdzYXkgIiAgKGV4aXN0
>> "!B64TMP!" echo aW5nIGZpbGVzIGluIHRoZSB0YXJnZXQgZm9sZGVyIGFyZSBvdmVyd3JpdHRlbikiJykKICAgIGFw
>> "!B64TMP!" echo KCcnKQogICAgYXAoJ2hkciAiU3RlcCAyIG9mIDM6IEJ1aWxkIG5vdz8iJykKICAgIGFwKCdzYXkg
>> "!B64TMP!" echo IiAgR2VuZXJhdGUgaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0Ly5zaCB3aXRoIFB5dGhvbiByaWdo
>> "!B64TMP!" echo dCBhZnRlciB1bnBhY2tpbmc/IicpCiAgICBhcCgncHJpbnRmICIgIFJ1biB0aGUgaW5zdGFsbGVy
>> "!B64TMP!" echo IGJ1aWxkIG5vdz8gW1kvbl06ICInKQogICAgYXAoJ3JlYWQgLXIgQlVJTEROT1cnKQogICAgYXAo
>> "!B64TMP!" echo JycpCiAgICBhcCgnaGRyICJTdGVwIDMgb2YgMzogQ29uZmlybSInKQogICAgYXAoJ3NheSAiICBX
>> "!B64TMP!" echo aWxsIHVucGFjayAlZCBmaWxlcyBpbnRvOiAkVEFSR0VUIicgJSBOX0ZJTEVTKQogICAgYXAoJ3By
>> "!B64TMP!" echo aW50ZiAiUHJvY2VlZD8gW1kvbl06ICInKQogICAgYXAoJ3JlYWQgLXIgQ09ORklSTScpCiAgICBh
>> "!B64TMP!" echo cCgnaWYgWyAiJChsb3dlciAiJENPTkZJUk0iKSIgPSAibiIgXTsgdGhlbiBzYXkgIkNhbmNlbGxl
>> "!B64TMP!" echo ZC4iOyBleGl0IDA7IGZpJykKICAgIGFwKCcnKQogICAgYXAoJ21rZGlyIC1wICIkVEFSR0VUL2xv
>> "!B64TMP!" echo Y2FsLXNlYXJjaC9jb25maWcvc2VhcnhuZyIgIiRUQVJHRVQvbG9jYWwtc2VhcmNoL2xvY2FsLXdl
>> "!B64TMP!" echo Yi1zZWFyY2gvc2NyaXB0cyInKQogICAgYXAoJycpCiAgICBhcCgnc2F5ICJVbnBhY2tpbmcgZmls
>> "!B64TMP!" echo ZXMuLi4iJykKCiAgICBkZWYgaGVyZWRvY19ibG9jayhyZWxfcGF0aCwgZGF0YSk6CiAgICAgICAg
>> "!B64TMP!" echo dGV4dCA9IGRhdGEuZGVjb2RlKCJ1dGYtOCIpCiAgICAgICAgIyBMRi1ub3JtYWxpc2UgdGhlIGhl
>> "!B64TMP!" echo cmVkb2MgYm9keTsgdGhlIGF3ayBsb29wIGJlbG93IHJlc3RvcmVzIENSTEYgZm9yCiAgICAgICAg
>> "!B64TMP!" echo IyBldmVyeSAuYmF0IGZpbGUgYWZ0ZXIgdW5wYWNraW5nLgogICAgICAgIHRleHRfbGYgPSB0ZXh0
>> "!B64TMP!" echo LnJlcGxhY2UoIlxyXG4iLCAiXG4iKS5yZXBsYWNlKCJcciIsICJcbiIpCiAgICAgICAgdGFnID0g
>> "!B64TMP!" echo dGFnX2ZvcihyZWxfcGF0aCkKICAgICAgICBhcCgnJykKICAgICAgICBhcCgnIyAtLS0gJyArIHJl
>> "!B64TMP!" echo bF9wYXRoICsgJyAtLS0nKQogICAgICAgIGFwKCdjYXQgPiAiJFRBUkdFVC8nICsgcmVsX3BhdGgg
>> "!B64TMP!" echo KyAnIiA8PFwnJyArIHRhZyArICdcJycpCiAgICAgICAgZm9yIGxpbmUgaW4gdGV4dF9sZi5zcGxp
>> "!B64TMP!" echo dGxpbmVzKCk6CiAgICAgICAgICAgIGFwKGxpbmUpCiAgICAgICAgYXAodGFnKQoKICAgICMgbG9j
>> "!B64TMP!" echo YWwtc2VhcmNoIHNvdXJjZXMKICAgIGZvciByZWwgaW4gU09VUkNFX0ZJTEVTOgogICAgICAgIGhl
>> "!B64TMP!" echo cmVkb2NfYmxvY2soImxvY2FsLXNlYXJjaC8iICsgcmVsLCByZWFkX3NyYyhyZWwpKQogICAgIyBy
>> "!B64TMP!" echo aWcgZmlsZXMKICAgIGZvciByZWwgaW4gUklHX0ZJTEVTOgogICAgICAgIGhlcmVkb2NfYmxvY2so
>> "!B64TMP!" echo cmVsLCByZWFkX3Jvb3QocmVsKSkKICAgICMgdGhlIFdpbmRvd3MgcGFja2VyLCBzbyB0aGlzIG9u
>> "!B64TMP!" echo ZSBmaWxlIHJlcHJvZHVjZXMgdGhlIHdob2xlIHJpZwogICAgaGVyZWRvY19ibG9jaygibG9jYWwt
>> "!B64TMP!" echo c2VhcmNoLXJpZy5iYXQiLCByZWFkX3Jvb3QoImxvY2FsLXNlYXJjaC1yaWcuYmF0IikpCgogICAg
>> "!B64TMP!" echo YXAoJycpCiAgICBhcCgnIyBLZWVwIGEgY29weSBvZiB0aGlzIHBhY2tlciBpbiB0aGUgdGFyZ2V0
>> "!B64TMP!" echo IHNvIHRoZSByaWcgaXMgY29tcGxldGUuJykKICAgIGFwKCdjcCAtZiAiJDAiICIkVEFSR0VUL2xv
>> "!B64TMP!" echo Y2FsLXNlYXJjaC1yaWcuc2giJykKICAgIGFwKCdjaG1vZCAreCAiJFRBUkdFVCIvKi5zaCAiJFRB
>> "!B64TMP!" echo UkdFVCIvbG9jYWwtc2VhcmNoLyouc2ggMj4vZGV2L251bGwgfHwgdHJ1ZScpCiAgICBhcCgnJykK
>> "!B64TMP!" echo ICAgIGFwKCcjIFJlc3RvcmUgQ1JMRiBsaW5lIGVuZGluZ3MgZm9yIGV2ZXJ5IC5iYXQgZmlsZSAo
>> "!B64TMP!" echo dGhlIGhlcmVkb2NzIGFib3ZlJykKICAgIGFwKCcjIHdyb3RlIExGOyBhd2sgaXMgdXNlZCBpbnN0
>> "!B64TMP!" echo ZWFkIG9mIHNlZCBzbyB0aGlzIGFsc28gd29ya3Mgb24gbWFjT1MpLicpCiAgICBhcCgnZmluZCAi
>> "!B64TMP!" echo JFRBUkdFVCIgLXR5cGUgZiAtbmFtZSBcJyouYmF0XCcgMj4vZGV2L251bGwgfCB3aGlsZSBJRlM9
>> "!B64TMP!" echo IHJlYWQgLXIgZjsgZG8nKQogICAgYXAoJyAgYXdrIFwne3N1YigvXFxyJC8sIiIpOyBwcmludGYg
>> "!B64TMP!" echo IiVzXFxyXFxuIiwgJDB9XCcgIiRmIiA+ICIkZi5jcmxmIiAyPi9kZXYvbnVsbCBcXCcpCiAgICBh
>> "!B64TMP!" echo cCgnICAgICYmIG12ICIkZi5jcmxmIiAiJGYiIHx8IHJtIC1mICIkZi5jcmxmIicpCiAgICBhcCgn
>> "!B64TMP!" echo ZG9uZScpCiAgICBhcCgnJykKICAgIGFwKCdvayAiVW5wYWNrZWQgdGhlIGRldiByaWcgaW50bzog
>> "!B64TMP!" echo JFRBUkdFVCInKQogICAgYXAoJycpCiAgICAjIE9wdGlvbmFsIGJ1aWxkCiAgICBhcCgnaWYgWyAi
>> "!B64TMP!" echo JChsb3dlciAiJHtCVUlMRE5PVzoteX0iKSIgIT0gIm4iIF07IHRoZW4nKQogICAgYXAoJyAgUFk9
>> "!B64TMP!" echo IiQoY29tbWFuZCAtdiBweXRob24zIHx8IGNvbW1hbmQgLXYgcHl0aG9uKSInKQogICAgYXAoJyAg
>> "!B64TMP!" echo aWYgWyAtbiAiJFBZIiBdOyB0aGVuJykKICAgIGFwKCcgICAgc2F5ICJCdWlsZGluZyBpbnN0YWxs
>> "!B64TMP!" echo ZXJzIHdpdGggJFBZIC4uLiInKQogICAgYXAoJyAgICBpZiAoY2QgIiRUQVJHRVQiICYmICIkUFki
>> "!B64TMP!" echo IGdlbl9pbnN0YWxsZXJzLnB5KTsgdGhlbicpCiAgICBhcCgnICAgICAgc2F5ICIgIEluc3RhbGxl
>> "!B64TMP!" echo cnMgd3JpdHRlbiB0byAkVEFSR0VUL2xvY2FsLXNlYXJjaC8iJykKICAgIGFwKCcgICAgZWxzZScp
>> "!B64TMP!" echo CiAgICBhcCgnICAgICAgZXJyICJnZW5faW5zdGFsbGVycy5weSBmYWlsZWQgLSBzZWUgb3V0cHV0
>> "!B64TMP!" echo IGFib3ZlLiInKQogICAgYXAoJyAgICBmaScpCiAgICBhcCgnICBlbHNlJykKICAgIGFwKCcgICAg
>> "!B64TMP!" echo c2F5ICIgICR7WUVMTE9XfVtXQVJOSU5HXSR7UkVTRVR9IFB5dGhvbiBub3QgZm91bmQgLSBza2lw
>> "!B64TMP!" echo cGluZyB0aGUgYnVpbGQuIicpCiAgICBhcCgnICAgIHNheSAiICBJbnN0YWxsIFB5dGhvbiAzLjgr
>> "!B64TMP!" echo LCB0aGVuIHJ1biAuL2J1aWxkLnNoIGluIHRoZSB0YXJnZXQgZm9sZGVyLiInKQogICAgYXAoJyAg
>> "!B64TMP!" echo ZmknKQogICAgYXAoJ2ZpJykKICAgIGFwKCcnKQogICAgIyBEb25lCiAgICBhcCgnZWNobycpCiAg
>> "!B64TMP!" echo ICBhcCgnc2F5ICIke0dSRUVOfT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PSR7UkVTRVR9IicpCiAgICBhcCgnc2F5ICIke0dSRUVOfSAg
>> "!B64TMP!" echo RGV2IHJpZyByZWFkeTogJFRBUkdFVCR7UkVTRVR9IicpCiAgICBhcCgnZWNobycpCiAgICBhcCgn
>> "!B64TMP!" echo c2F5ICIgIE5leHQgc3RlcHMgKHNlZSBCVUlMRC5tZCBpbnNpZGUpOiInKQogICAgYXAoJ3NheSAi
>> "!B64TMP!" echo ICAgIC4vYnVpbGQuc2ggICAgICAgICAgICAgICAgICAgIHJlYnVpbGQgaW5zdGFsbGVycyArIHBh
>> "!B64TMP!" echo Y2tlcnMgKyB0ZXN0cyInKQogICAgYXAoJ3NheSAiICAgIHB5dGhvbjMgZ2VuX2luc3RhbGxlcnMu
>> "!B64TMP!" echo cHkgICAgIHJlYnVpbGQganVzdCB0aGUgaW5zdGFsbGVycyInKQogICAgYXAoJ3NheSAiICAgIHB5
>> "!B64TMP!" echo dGhvbjMgZ2VuX3JpZy5weSAgICAgICAgICAgIHJlYnVpbGQgdGhlc2UgcGFja2VycyInKQogICAg
>> "!B64TMP!" echo YXAoJ3NheSAiJHtHUkVFTn09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT0ke1JFU0VUfSInKQoKICAgIHJldHVybiAiXG4iLmpvaW4ob3V0
>> "!B64TMP!" echo KSArICJcbiIKCgpkZWYgbWFpbigpOgogICAgIyBXcml0ZSB0aGUgLmJhdCBwYWNrZXIgRklSU1Q6
>> "!B64TMP!" echo IHRoZSAuc2ggcGFja2VyIGVtYmVkcyBpdCwgc28gaXQgbXVzdCByZWFkCiAgICAjIHRoZSBmcmVz
>> "!B64TMP!" echo aGx5LXdyaXR0ZW4gZmlsZSAobm90IGEgc3RhbGUgcHJldmlvdXMtZ2VuZXJhdGlvbiBjb3B5KS4K
>> "!B64TMP!" echo ICAgIGJhdCA9IGdlbl9iYXRfcGFja2VyKCkKICAgIHdpdGggb3Blbihvcy5wYXRoLmpvaW4oUk9P
>> "!B64TMP!" echo VCwgImxvY2FsLXNlYXJjaC1yaWcuYmF0IiksICJ3YiIpIGFzIGY6CiAgICAgICAgZi53cml0ZShi
>> "!B64TMP!" echo YXQuZW5jb2RlKCJ1dGYtOCIpKQogICAgc2ggPSBnZW5fc2hfcGFja2VyKCkKICAgIHdpdGggb3Bl
>> "!B64TMP!" echo bihvcy5wYXRoLmpvaW4oUk9PVCwgImxvY2FsLXNlYXJjaC1yaWcuc2giKSwgIndiIikgYXMgZjoK
>> "!B64TMP!" echo ICAgICAgICBmLndyaXRlKHNoLmVuY29kZSgidXRmLTgiKSkKICAgIG9zLmNobW9kKG9zLnBhdGgu
>> "!B64TMP!" echo am9pbihST09ULCAibG9jYWwtc2VhcmNoLXJpZy5zaCIpLCAwbzc1NSkKICAgIHByaW50KCJXcm90
>> "!B64TMP!" echo ZSBsb2NhbC1zZWFyY2gtcmlnLmJhdCAoJWQgYnl0ZXMpIiAlIGxlbihiYXQpKQogICAgcHJpbnQo
>> "!B64TMP!" echo Ildyb3RlIGxvY2FsLXNlYXJjaC1yaWcuc2ggICglZCBieXRlcykiICUgbGVuKHNoKSkKCgppZiBf
>> "!B64TMP!" echo X25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg==
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
>> "!B64TMP!" echo aXB0cy93ZWJfeW91dHViZV90cmFuc2NyaXB0LnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3Nj
>> "!B64TMP!" echo cmlwdHMvd2ViX21hcC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9jcmF3
>> "!B64TMP!" echo bC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9jcmF3bF9zdGF0dXMucHki
>> "!B64TMP!" echo LAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfYWdlbnQucHkiLAogICAgImxvY2Fs
>> "!B64TMP!" echo LXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfYWdlbnRfc3RhdHVzLnB5IiwKICAgICJsb2NhbC13ZWIt
>> "!B64TMP!" echo c2VhcmNoL3NjcmlwdHMvd2ViX2ludGVyYWN0LnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3Nj
>> "!B64TMP!" echo cmlwdHMvd2ViX2ludGVyYWN0X3N0b3AucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfcGFyc2UucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRv
>> "!B64TMP!" echo cl9jcmVhdGUucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9s
>> "!B64TMP!" echo aXN0LnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfZ2V0LnB5
>> "!B64TMP!" echo IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfdXBkYXRlLnB5IiwK
>> "!B64TMP!" echo ICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfZGVsZXRlLnB5IiwKICAg
>> "!B64TMP!" echo ICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfcnVuLnB5IiwKICAgICJsb2Nh
>> "!B64TMP!" echo bC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfY2hlY2tzLnB5IiwKICAgICJsb2NhbC13
>> "!B64TMP!" echo ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfY2hlY2sucHkiLAogICAgImxvY2FsLXdlYi1z
>> "!B64TMP!" echo ZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfc2VhcmNoLnB5IiwKICAgICJsb2NhbC13ZWItc2Vh
>> "!B64TMP!" echo cmNoL3NjcmlwdHMvd2ViX3Jlc2VhcmNoX2luc3BlY3QucHkiLAogICAgImxvY2FsLXdlYi1zZWFy
>> "!B64TMP!" echo Y2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfcmVsYXRlZC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJj
>> "!B64TMP!" echo aC9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWFkLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3Nj
>> "!B64TMP!" echo cmlwdHMvd2ViX2dpdGh1Yl9zZWFyY2gucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0
>> "!B64TMP!" echo cy93ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSIsCl0KCmRlZiByZWFkKHJlbCk6CiAgICB3aXRoIG9w
>> "!B64TMP!" echo ZW4ob3MucGF0aC5qb2luKFNSQywgcmVsKSwgInJiIikgYXMgZjoKICAgICAgICByZXR1cm4gZi5y
>> "!B64TMP!" echo ZWFkKCkKCiMgLS0tLSBleHRyYWN0IGJhc2U2NCBibG9ja3MgZnJvbSB0aGUgLmJhdCAtLS0tCmJh
>> "!B64TMP!" echo dF90ZXh0ID0gb3BlbihCQVQsICJyIiwgZW5jb2Rpbmc9InV0Zi04IikucmVhZCgpCiMgQSBibG9j
>> "!B64TMP!" echo ayBsb29rcyBsaWtlOgojICAgUkVNIC0tLSA8cmVsPiAtLS0KIyAgIHNldCAiTkVFRF9CNjQ9MSIK
>> "!B64TMP!" echo IyAgIC4uLgojICAgc2V0ICJCNjRUTVA9JVRFTVAlXExTeHh4eHh4LmI2NCIKIyAgID4gIiFCNjRU
>> "!B64TMP!" echo TVAhIiBlY2hvIExJTkUxCiMgICA+PiAiIUI2NFRNUCEiIGVjaG8gTElORTIKIyAgIC4uLgojICAg
>> "!B64TMP!" echo c2V0ICJMU19CNjRfSU49Li4uIgpibG9ja3MgPSB7fQpjdXJfcmVsID0gTm9uZQpjdXJfbGluZXMg
>> "!B64TMP!" echo PSBbXQpmb3IgbGluZSBpbiBiYXRfdGV4dC5zcGxpdCgiXG4iKToKICAgIG0gPSByZS5tYXRjaChy
>> "!B64TMP!" echo J1JFTSAtLS0gKC4rPykgLS0tJCcsIGxpbmUpCiAgICBpZiBtOgogICAgICAgIGlmIGN1cl9yZWw6
>> "!B64TMP!" echo CiAgICAgICAgICAgIGJsb2Nrc1tjdXJfcmVsXSA9IGN1cl9saW5lcwogICAgICAgIGN1cl9yZWwg
>> "!B64TMP!" echo PSBtLmdyb3VwKDEpCiAgICAgICAgY3VyX2xpbmVzID0gW10KICAgICAgICBjb250aW51ZQogICAg
>> "!B64TMP!" echo bTIgPSByZS5tYXRjaChyJ1xzKj4+P1xzKiIhQjY0VE1QISJccytlY2hvXHMrKC4rKSQnLCBsaW5l
>> "!B64TMP!" echo KQogICAgaWYgbTIgYW5kIGN1cl9yZWw6CiAgICAgICAgY3VyX2xpbmVzLmFwcGVuZChtMi5ncm91
>> "!B64TMP!" echo cCgxKSkKaWYgY3VyX3JlbDoKICAgIGJsb2Nrc1tjdXJfcmVsXSA9IGN1cl9saW5lcwoKcHJpbnQo
>> "!B64TMP!" echo IkZvdW5kICVkIGVtYmVkZGVkIGJhc2U2NCBibG9ja3MgaW4gLmJhdCIgJSBsZW4oYmxvY2tzKSkK
>> "!B64TMP!" echo b2sgPSBUcnVlCmZvciByZWwgaW4gRklMRVM6CiAgICBvcmlnID0gcmVhZChyZWwpCiAgICBpZiBy
>> "!B64TMP!" echo ZWwgbm90IGluIGJsb2NrczoKICAgICAgICBwcmludCgiICBbTUlTU10gJS0zMnMgOiBubyBiYXNl
>> "!B64TMP!" echo NjQgYmxvY2sgaW4gLmJhdCIgJSByZWwpCiAgICAgICAgb2sgPSBGYWxzZQogICAgICAgIGNvbnRp
>> "!B64TMP!" echo bnVlCiAgICAjIGNvbmNhdGVuYXRlIGFuZCBzdHJpcCB3aGl0ZXNwYWNlIChtaXJyb3JzIFBTIC1y
>> "!B64TMP!" echo ZXBsYWNlICdccycsJycpCiAgICBqb2luZWQgPSAiIi5qb2luKGJsb2Nrc1tyZWxdKQogICAgdHJ5
>> "!B64TMP!" echo OgogICAgICAgIGRlYyA9IGJhc2U2NC5iNjRkZWNvZGUoam9pbmVkKQogICAgZXhjZXB0IEV4Y2Vw
>> "!B64TMP!" echo dGlvbiBhcyBlOgogICAgICAgIHByaW50KCIgIFtGQUlMXSAlLTMycyA6IGI2NCBkZWNvZGUgZXJy
>> "!B64TMP!" echo b3I6ICVzIiAlIChyZWwsIGUpKQogICAgICAgIG9rID0gRmFsc2UKICAgICAgICBjb250aW51ZQog
>> "!B64TMP!" echo ICAgaWYgZGVjID09IG9yaWc6CiAgICAgICAgcHJpbnQoIiAgW09LXSAgICUtMzJzIDogJWQgYnl0
>> "!B64TMP!" echo ZXMgcm91bmQtdHJpcCBPSyIgJSAocmVsLCBsZW4ob3JpZykpKQogICAgZWxzZToKICAgICAgICBw
>> "!B64TMP!" echo cmludCgiICBbRkFJTF0gJS0zMnMgOiBkZWNvZGVkICVkIGJ5dGVzICE9IG9yaWdpbmFsICVkIGJ5
>> "!B64TMP!" echo dGVzIiAlIChyZWwsIGxlbihkZWMpLCBsZW4ob3JpZykpKQogICAgICAgIG9rID0gRmFsc2UKCiMg
>> "!B64TMP!" echo LS0tLSBjbWQuZXhlIGJsb2NrLXBhcmVuIHNhZmV0eSBjaGVjayBvbiB0aGUgLmJhdCBsb2dpYyBs
>> "!B64TMP!" echo aW5lcyAtLS0tCiMgUmVhbCBjbWQuZXhlIHJ1bGUgKHZlcmlmaWVkIGFnYWluc3QgYSByZWFsIGNt
>> "!B64TMP!" echo ZC5leGUgaW1wbGVtZW50YXRpb24pOgojICAgKiBhbiB1bnF1b3RlZC91bmVzY2FwZWQgIigiIGlu
>> "!B64TMP!" echo IGVjaG8gdGV4dCBpcyBJTkVSVCAobGl0ZXJhbCB0ZXh0KSwKIyAgICogYnV0IGFuIHVucXVvdGVk
>> "!B64TMP!" echo L3VuZXNjYXBlZCAiKSIgSU5TSURFIGEgcGFyZW50aGVzaXplZCBibG9jayBpcwojICAgICBTVFJV
>> "!B64TMP!" echo Q1RVUkFMOiBpdCBjbG9zZXMgdGhlIGJsb2NrIGF0IHRoYXQgcG9pbnQuIElmIHRoZSAiKSIgaXMg
>> "!B64TMP!" echo aW4gdGhlCiMgICAgIG1pZGRsZSBvZiBhIGNvbW1hbmQncyB0ZXh0LCB0aGUgcmVtYWluZGVyIG9m
>> "!B64TMP!" echo IHRoZSBzdGF0ZW1lbnQgYmVjb21lcwojICAgICB0b3AtbGV2ZWwgZ2FyYmFnZSAtPiAiRk9SIHdh
>> "!B64TMP!" echo cyB1bmV4cGVjdGVkIGF0IHRoaXMgdGltZSIgKG9yIHNpbWlsYXIpCiMgICAgIC0+IGNtZC5leGUg
>> "!B64TMP!" echo YWJvcnRzIHRoZSBiYXRjaCBhbmQgdGhlIHdpbmRvdyBjbG9zZXMuCiMgU286IHdoaWxlIGEgYmxv
>> "!B64TMP!" echo Y2sgaXMgb3BlbiwgZXZlcnkgdW5xdW90ZWQvdW5lc2NhcGVkICIpIiBtdXN0IGJlIGEKIyBsZWdp
>> "!B64TMP!" echo dGltYXRlIGNsb3NlcjogYSAiKSItbGluZSwgIikgZWxzZSAoIiwgb3IgZm9sbG93ZWQgYnkgZG8v
>> "!B64TMP!" echo Ji98L0VPTC4KZGVmIF91bnF1b3RlZF9wYXJlbnMobGluZSk6CiAgICBvdXQgPSBbXQogICAgaiA9
>> "!B64TMP!" echo IDA7IGlucSA9IEZhbHNlCiAgICB3aGlsZSBqIDwgbGVuKGxpbmUpOgogICAgICAgIGMgPSBsaW5l
>> "!B64TMP!" echo W2pdCiAgICAgICAgaWYgYyA9PSAiXiI6CiAgICAgICAgICAgIGogKz0gMjsgY29udGludWUKICAg
>> "!B64TMP!" echo ICAgICBpZiBjID09ICciJzoKICAgICAgICAgICAgaW5xID0gbm90IGlucTsgaiArPSAxOyBjb250
>> "!B64TMP!" echo aW51ZQogICAgICAgIGlmIG5vdCBpbnEgYW5kIGMgaW4gIigpIjoKICAgICAgICAgICAgb3V0LmFw
>> "!B64TMP!" echo cGVuZCgoaiwgYykpCiAgICAgICAgaiArPSAxCiAgICByZXR1cm4gb3V0CgpfY2xvc2VfY29udCA9
>> "!B64TMP!" echo IHJlLmNvbXBpbGUocideKGVsc2VcYnxkb1xifCZ8XHx8cmVtXGJ8OjopJywgcmUuSSkKYjY0bGlu
>> "!B64TMP!" echo ZSA9IHJlLmNvbXBpbGUocidccyo+Pj9ccyoiPyE/QjY0VE1QIT8iP1xzK2VjaG9ccysnKQpyZW1s
>> "!B64TMP!" echo aW5lID0gcmUuY29tcGlsZShyJ15ccyooUkVNXGJ8OjopJywgcmUuSSkKYmF0X2xpbmVzID0gYmF0
>> "!B64TMP!" echo X3RleHQuc3BsaXQoIlxuIikKcGFyZW5fYmFkID0gW10KZGVwdGggPSAwCmZvciBpLCBsaW5lIGlu
>> "!B64TMP!" echo IGVudW1lcmF0ZShiYXRfbGluZXMpOgogICAgaWYgYjY0bGluZS5tYXRjaChsaW5lKSBvciByZW1s
>> "!B64TMP!" echo aW5lLm1hdGNoKGxpbmUpIG9yIG5vdCBsaW5lLnN0cmlwKCk6CiAgICAgICAgY29udGludWUKICAg
>> "!B64TMP!" echo ICMgc2tpcCBlbWJlZGRlZC1iYXNlNjQgdGVtcC1maWxlIHdyaXRlcwogICAgcHMgPSBfdW5xdW90
>> "!B64TMP!" echo ZWRfcGFyZW5zKGxpbmUpCiAgICBjbG9zZXMgPSBbcCBmb3IgcCBpbiBwcyBpZiBwWzFdID09ICIp
>> "!B64TMP!" echo Il0KICAgIG9wZW5zID0gbGVuKFtwIGZvciBwIGluIHBzIGlmIHBbMV0gPT0gIigiXSkKICAgICMg
>> "!B64TMP!" echo c3RydWN0dXJhbCBvcGVuczogIigiIGF0IGVuZCBvZiBsaW5lIChpZi9mb3IvZG8gYmxvY2tzKSAr
>> "!B64TMP!" echo IGlubGluZQogICAgIyBmb3Itc2V0L2RvIG9wZW5zICgiaW4gKCIsICJkbyAoIikKICAgIHN0cnVj
>> "!B64TMP!" echo dHVyYWxfb3BlbnMgPSAwCiAgICBpZiBsaW5lLnJzdHJpcCgpLmVuZHN3aXRoKCIoIik6CiAgICAg
>> "!B64TMP!" echo ICAgc3RydWN0dXJhbF9vcGVucyArPSAxCiAgICBpbmxpbmUgPSBsZW4ocmUuZmluZGFsbChyIlxi
>> "!B64TMP!" echo aW5ccypcKCIsIGxpbmUpKSArIGxlbihyZS5maW5kYWxsKHIiXGJkb1xzKlwoIiwgbGluZSkpCiAg
>> "!B64TMP!" echo ICBpZiBsaW5lLnJzdHJpcCgpLmVuZHN3aXRoKCIoIikgYW5kIGlubGluZToKICAgICAgICBpbmxp
>> "!B64TMP!" echo bmUgPSBtYXgoMCwgaW5saW5lIC0gMSkKICAgIHN0cnVjdHVyYWxfb3BlbnMgKz0gaW5saW5lCiAg
>> "!B64TMP!" echo ICBpZiBkZXB0aCA+IDAgYW5kIGNsb3NlczoKICAgICAgICBmb3IgcG9zLCBfY2ggaW4gY2xvc2Vz
>> "!B64TMP!" echo OgogICAgICAgICAgICBhZnRlciA9IGxpbmVbcG9zICsgMTpdLmxzdHJpcCgpCiAgICAgICAgICAg
>> "!B64TMP!" echo IGlmIGFmdGVyID09ICIiIG9yIF9jbG9zZV9jb250Lm1hdGNoKGFmdGVyKToKICAgICAgICAgICAg
>> "!B64TMP!" echo ICAgIGNvbnRpbnVlICAjIGxlZ2l0aW1hdGUgY2xvc2VyCiAgICAgICAgICAgIHBhcmVuX2JhZC5h
>> "!B64TMP!" echo cHBlbmQoKGkgKyAxLCBsaW5lLnN0cmlwKCkpKQogICAgICAgICAgICBicmVhawogICAgZGVwdGgg
>> "!B64TMP!" echo Kz0gc3RydWN0dXJhbF9vcGVucyAtIGxlbihjbG9zZXMpCiAgICBpZiBkZXB0aCA8IDA6CiAgICAg
>> "!B64TMP!" echo ICAgZGVwdGggPSAwICAjIHRvcC1sZXZlbCAiKSIgaW4gZWNobyB0ZXh0IGlzIGEgbGl0ZXJhbCwg
>> "!B64TMP!" echo aGFybWxlc3MKaWYgcGFyZW5fYmFkOgogICAgcHJpbnQoKQogICAgcHJpbnQoIltGQUlMXSB1bmVz
>> "!B64TMP!" echo Y2FwZWQgJyknIGluc2lkZSBibG9ja3MgKGtpbGxzIHJlYWwgY21kLmV4ZSk6IikKICAgIGZvciBs
>> "!B64TMP!" echo biwgdHh0IGluIHBhcmVuX2JhZDoKICAgICAgICBwcmludCgiICBMJWQ6ICVzIiAlIChsbiwgdHh0
>> "!B64TMP!" echo KSkKICAgIG9rID0gRmFsc2UKZWxzZToKICAgIHByaW50KCJwYXJlbiBjaGVjazogbm8gdW5lc2Nh
>> "!B64TMP!" echo cGVkICcpJyBpbnNpZGUgYmxvY2tzIChjbWQtc2FmZSkiKQoKcHJpbnQoKQpwcmludCgiQUxMIEdP
>> "!B64TMP!" echo T0QiIGlmIG9rIGVsc2UgIkZBSUxVUkVTIFBSRVNFTlQiKQppbXBvcnQgc3lzCnN5cy5leGl0KDAg
>> "!B64TMP!" echo aWYgb2sgZWxzZSAxKQo=
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
>> "!B64TMP!" echo ImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfeW91dHViZV90cmFuc2NyaXB0LnB5IiwKICAg
>> "!B64TMP!" echo ICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21hcC5weSIsCiAgICAibG9jYWwtd2ViLXNl
>> "!B64TMP!" echo YXJjaC9zY3JpcHRzL3dlYl9jcmF3bC5weSIsCiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9jcmF3bF9zdGF0dXMucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJf
>> "!B64TMP!" echo YWdlbnQucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfYWdlbnRfc3RhdHVz
>> "!B64TMP!" echo LnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2ludGVyYWN0LnB5IiwKICAg
>> "!B64TMP!" echo ICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2ludGVyYWN0X3N0b3AucHkiLAogICAgImxv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfcGFyc2UucHkiLAogICAgImxvY2FsLXdlYi1zZWFy
>> "!B64TMP!" echo Y2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9jcmVhdGUucHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gv
>> "!B64TMP!" echo c2NyaXB0cy93ZWJfbW9uaXRvcl9saXN0LnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3Njcmlw
>> "!B64TMP!" echo dHMvd2ViX21vbml0b3JfZ2V0LnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2Vi
>> "!B64TMP!" echo X21vbml0b3JfdXBkYXRlLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21v
>> "!B64TMP!" echo bml0b3JfZGVsZXRlLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0
>> "!B64TMP!" echo b3JfcnVuLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfY2hl
>> "!B64TMP!" echo Y2tzLnB5IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX21vbml0b3JfY2hlY2su
>> "!B64TMP!" echo cHkiLAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfc2VhcmNoLnB5
>> "!B64TMP!" echo IiwKICAgICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3Jlc2VhcmNoX2luc3BlY3QucHki
>> "!B64TMP!" echo LAogICAgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfcmVzZWFyY2hfcmVsYXRlZC5weSIs
>> "!B64TMP!" echo CiAgICAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWFkLnB5IiwKICAg
>> "!B64TMP!" echo ICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2dpdGh1Yl9zZWFyY2gucHkiLAogICAgImxv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSIsCiAgICAiaW5z
>> "!B64TMP!" echo dGFsbC1sb2NhbC1zZWFyY2guYmF0IiwKXQoKZGVmIHJlYWQocmVsKToKICAgIHdpdGggb3Blbihv
>> "!B64TMP!" echo cy5wYXRoLmpvaW4oU1JDLCByZWwpLCAicmIiKSBhcyBmOgogICAgICAgIHJldHVybiBmLnJlYWQo
>> "!B64TMP!" echo KQoKIyBGaW5kIGJsb2NrcyBvZiB0aGUgZm9ybToKIyAgIGNhdCA+ICIkVEFSR0VULzxyZWw+IiA8
>> "!B64TMP!" echo PCc8VEFHPicKIyAgIDxib2R5PgojICAgPFRBRz4KaGVyZWRvY3MgPSB7fQpsaW5lcyA9IHRleHQu
>> "!B64TMP!" echo c3BsaXQoIlxuIikKaSA9IDAKd2hpbGUgaSA8IGxlbihsaW5lcyk6CiAgICBtID0gcmUubWF0Y2go
>> "!B64TMP!" echo ciJccypjYXQgPiBcIlwkVEFSR0VULyguKz8pXCIgPDwnKFtBLVowLTlfXSspJyQiLCBsaW5lc1tp
>> "!B64TMP!" echo XSkKICAgIGlmIG06CiAgICAgICAgcmVsLCB0YWcgPSBtLmdyb3VwKDEpLCBtLmdyb3VwKDIpCiAg
>> "!B64TMP!" echo ICAgICAgYm9keV9zdGFydCA9IGkgKyAxCiAgICAgICAgIyBmaW5kIGNsb3NpbmcgdGFnCiAgICAg
>> "!B64TMP!" echo ICAgaiA9IGJvZHlfc3RhcnQKICAgICAgICB3aGlsZSBqIDwgbGVuKGxpbmVzKSBhbmQgbGluZXNb
>> "!B64TMP!" echo al0gIT0gdGFnOgogICAgICAgICAgICBqICs9IDEKICAgICAgICBib2R5ID0gIlxuIi5qb2luKGxp
>> "!B64TMP!" echo bmVzW2JvZHlfc3RhcnQ6al0pCiAgICAgICAgIyBldmVyeSBoZXJlZG9jIGxpbmUgKGluY2x1ZGlu
>> "!B64TMP!" echo ZyB0aGUgbGFzdCkgaXMgd3JpdHRlbiB3aXRoIGEgdHJhaWxpbmcKICAgICAgICAjIG5ld2xpbmUg
>> "!B64TMP!" echo YnkgdGhlIHNoZWxsLCBzbyBhcHBlbmQgaXQgYmFjayBhZnRlciB0aGUgam9pbi4KICAgICAgICBp
>> "!B64TMP!" echo ZiBib2R5X3N0YXJ0IDw9IGo6CiAgICAgICAgICAgIGJvZHkgKz0gIlxuIgogICAgICAgIGhlcmVk
>> "!B64TMP!" echo b2NzW3JlbF0gPSBib2R5CiAgICAgICAgaSA9IGogKyAxCiAgICBlbHNlOgogICAgICAgIGkgKz0g
>> "!B64TMP!" echo MQoKcHJpbnQoIkZvdW5kICVkIGhlcmVkb2NzIGluIC5zaCIgJSBsZW4oaGVyZWRvY3MpKQpvayA9
>> "!B64TMP!" echo IFRydWUKZm9yIHJlbCBpbiBGSUxFUzoKICAgIG9yaWcgPSByZWFkKHJlbCkuZGVjb2RlKCJ1dGYt
>> "!B64TMP!" echo OCIpCiAgICBpZiByZWwgbm90IGluIGhlcmVkb2NzOgogICAgICAgIHByaW50KCIgIFtNSVNTXSAl
>> "!B64TMP!" echo LTMycyIgJSByZWwpCiAgICAgICAgb2sgPSBGYWxzZQogICAgICAgIGNvbnRpbnVlCiAgICAjIENv
>> "!B64TMP!" echo bXBhcmUgY29udGVudCBpZ25vcmluZyBsaW5lLWVuZGluZyBkaWZmZXJlbmNlczogdGhlIC5zaCBp
>> "!B64TMP!" echo bnN0YWxsZXIKICAgICMgd3JpdGVzIC5iYXQgZmlsZXMgdmlhIGhlcmVkb2MgKExGKSBhbmQgdGhl
>> "!B64TMP!" echo biBhIHJ1bnRpbWUgQ1JMRi1jb252ZXJzaW9uCiAgICAjIGxvb3AgY29udmVydHMgdGhlbSB0byBD
>> "!B64TMP!" echo UkxGLiBTbyB0aGUgaGVyZWRvYyBib2R5IGhhcyBMRiB3aGVyZSB0aGUKICAgICMgb3JpZ2luYWwg
>> "!B64TMP!" echo LmJhdCBoYXMgQ1JMRiAtLSB0aGlzIGlzIGV4cGVjdGVkIGFuZCBjb3JyZWN0LgogICAgYSA9IGhl
>> "!B64TMP!" echo cmVkb2NzW3JlbF0ucmVwbGFjZSgiXHJcbiIsICJcbiIpCiAgICBiID0gb3JpZy5yZXBsYWNlKCJc
>> "!B64TMP!" echo clxuIiwgIlxuIikKICAgIGlmIGEgPT0gYjoKICAgICAgICBwcmludCgiICBbT0tdICAgJS0zMnMg
>> "!B64TMP!" echo OiAlZCBieXRlcyAoY29udGVudCBtYXRjaGVzOyBDUkxGIGZpeGVkIGF0IHJ1bnRpbWUpIiAlIChy
>> "!B64TMP!" echo ZWwsIGxlbihvcmlnKSkpCiAgICBlbHNlOgogICAgICAgIHByaW50KCIgIFtGQUlMXSAlLTMycyA6
>> "!B64TMP!" echo IGhlcmVkb2MgJWQgdnMgb3JpZyAlZCAoTEYtbm9ybWFsaXNlZCkiICUgKHJlbCwgbGVuKGEpLCBs
>> "!B64TMP!" echo ZW4oYikpKQogICAgICAgIGZvciBrIGluIHJhbmdlKG1pbihsZW4oYSksIGxlbihiKSkpOgogICAg
>> "!B64TMP!" echo ICAgICAgICBpZiBhW2tdICE9IGJba106CiAgICAgICAgICAgICAgICBwcmludCgiICAgIGZpcnN0
>> "!B64TMP!" echo IGRpZmYgYXQgYnl0ZSAlZDogaGVyZWRvYz0lciBvcmlnPSVyIiAlIChrLCBhW2s6ayszMF0sIGJb
>> "!B64TMP!" echo azprKzMwXSkpCiAgICAgICAgICAgICAgICBicmVhawogICAgICAgIG9rID0gRmFsc2UKCnByaW50
>> "!B64TMP!" echo KCkKcHJpbnQoIkFMTCBHT09EIiBpZiBvayBlbHNlICJGQUlMVVJFUyIpCg==
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
>> "!B64TMP!" echo ICAgIGFuZCB2ZXJpZmllcyBhbGwgMjUgdG9vbHMgaW5zdGFsbCwgdGhlIGNyZWRlbnRpYWxzIGxh
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
>> "!B64TMP!" echo ZS5weSIKY2hlY2sgImxvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfeW91dHViZV90cmFuc2Ny
>> "!B64TMP!" echo aXB0LnB5IgpjaGVjayAibG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9tYXAucHkiCmNoZWNr
>> "!B64TMP!" echo ICJsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2NyYXdsLnB5IgpjaGVjayAibG9jYWwtd2Vi
>> "!B64TMP!" echo LXNlYXJjaC9zY3JpcHRzL3dlYl9jcmF3bF9zdGF0dXMucHkiCmNoZWNrICJpbnN0YWxsLWxvY2Fs
>> "!B64TMP!" echo LXNlYXJjaC5iYXQiCmNoZWNrICJpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaCIKCiMgLS0tIGNvcmUt
>> "!B64TMP!" echo b25seSBtb2RlOiB0aGUgMTkgYWNjb3VudC1nYXRlZCBzY3JpcHRzIG11c3QgTk9UIGJlIGluc3Rh
>> "!B64TMP!" echo bGxlZCAtLS0tLS0KZWNobwplY2hvICJDaGVja2luZyB0aGUgYWNjb3VudC1nYXRlZCB0b29scyBh
>> "!B64TMP!" echo cmUgTk9UIGluc3RhbGxlZCAobm8gRmlyZWNyYXdsIGFjY291bnQpOiIKZm9yIGYgaW4gd2ViX2Fn
>> "!B64TMP!" echo ZW50LnB5IHdlYl9hZ2VudF9zdGF0dXMucHkgd2ViX2ludGVyYWN0LnB5IHdlYl9pbnRlcmFjdF9z
>> "!B64TMP!" echo dG9wLnB5IFwKICAgICAgICAgd2ViX3BhcnNlLnB5IHdlYl9tb25pdG9yX2NyZWF0ZS5weSB3ZWJf
>> "!B64TMP!" echo bW9uaXRvcl9saXN0LnB5IFwKICAgICAgICAgd2ViX21vbml0b3JfZ2V0LnB5IHdlYl9tb25pdG9y
>> "!B64TMP!" echo X3VwZGF0ZS5weSB3ZWJfbW9uaXRvcl9kZWxldGUucHkgXAogICAgICAgICB3ZWJfbW9uaXRvcl9y
>> "!B64TMP!" echo dW4ucHkgd2ViX21vbml0b3JfY2hlY2tzLnB5IHdlYl9tb25pdG9yX2NoZWNrLnB5IFwKICAgICAg
>> "!B64TMP!" echo ICAgd2ViX3Jlc2VhcmNoX3NlYXJjaC5weSB3ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSB3ZWJfcmVz
>> "!B64TMP!" echo ZWFyY2hfcmVsYXRlZC5weSBcCiAgICAgICAgIHdlYl9yZXNlYXJjaF9yZWFkLnB5IHdlYl9naXRo
>> "!B64TMP!" echo dWJfc2VhcmNoLnB5IHdlYl9kZXZlbG9wZXJfc2VhcmNoLnB5OyBkbwogIGNoZWNrX2Fic2VudCAi
>> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzLyRmIgpkb25lCmNoZWNrX2Fic2VudCAibG9jYWwtd2Vi
>> "!B64TMP!" echo LXNlYXJjaC9TS0lMTC1jb3JlLm1kIgoKIyBTS0lMTC5tZCBtdXN0IGJlIHRoZSBjb3JlLW9ubHkg
>> "!B64TMP!" echo dmFyaWFudCAobm8gYWNjb3VudCB0b29scyBtZW50aW9uZWQpCmlmIGdyZXAgLXEgIjYgdG9vbHM6
>> "!B64TMP!" echo IHNlYXJjaCwgc2NyYXBlLCBtYXAsIGNyYXdsLCBjcmF3bCBzdGF0dXMsIFlvdVR1YmUiICIkVEdU
>> "!B64TMP!" echo X0RJUi9sb2NhbC13ZWItc2VhcmNoL1NLSUxMLm1kIiBcCiAgICYmICEgZ3JlcCAtcSAid2ViX21v
>> "!B64TMP!" echo bml0b3JfY3JlYXRlIiAiJFRHVF9ESVIvbG9jYWwtd2ViLXNlYXJjaC9TS0lMTC5tZCIgXAogICAm
>> "!B64TMP!" echo JiAhIGdyZXAgLXEgIndlYl9kZXZlbG9wZXJfc2VhcmNoIiAiJFRHVF9ESVIvbG9jYWwtd2ViLXNl
>> "!B64TMP!" echo YXJjaC9TS0lMTC5tZCI7IHRoZW4KICBlY2hvICIgIFtPS10gICBsb2NhbC13ZWItc2VhcmNoL1NL
>> "!B64TMP!" echo SUxMLm1kIGlzIHRoZSBjb3JlLW9ubHkgdmFyaWFudCIKZWxzZQogIGVjaG8gIiAgW0ZBSUxdIGxv
>> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2gvU0tJTEwubWQgaXMgbm90IHRoZSBjb3JlLW9ubHkgdmFyaWFudCIKICBQ
>> "!B64TMP!" echo QVNTPTAKZmkKCiMgdmVyaWZ5IC5lbnYgaGFzIHRoZSBjaG9zZW4gcG9ydHMgKyBhIHJlYWwgc2Vj
>> "!B64TMP!" echo cmV0CmVjaG8KZWNobyAiLS0tLS0gLmVudiBjb250ZW50cyAtLS0tLSIKY2F0ICIkVEdUX0RJUi8u
>> "!B64TMP!" echo ZW52IgplY2hvICItLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIgoKaWYgZ3JlcCAtcSAiXlNFQVJY
>> "!B64TMP!" echo TkdfUE9SVD05OTkwJCIgIiRUR1RfRElSLy5lbnYiIFwKICAgJiYgZ3JlcCAtcSAiXkZJUkVDUkFX
>> "!B64TMP!" echo TF9QT1JUPTk5OTEkIiAiJFRHVF9ESVIvLmVudiIgXAogICAmJiBncmVwIC1xICJeU0VBUlhOR19T
>> "!B64TMP!" echo RUNSRVQ9WzAtOWEtZl1cezY0XH0kIiAiJFRHVF9ESVIvLmVudiI7IHRoZW4KICBlY2hvICJbT0td
>> "!B64TMP!" echo IC5lbnYgaGFzIGNvcnJlY3QgcG9ydHMgYW5kIGEgNjQtaGV4IHNlY3JldCIKZWxzZQogIGVjaG8g
>> "!B64TMP!" echo IltGQUlMXSAuZW52IGlzIG1hbGZvcm1lZCIKICBQQVNTPTAKZmkKCiMgY29yZSBtb2RlOiBubyBG
>> "!B64TMP!" echo aXJlY3Jhd2wgYWNjb3VudCBjcmVkZW50aWFscyBpbiAuZW52CmlmIGdyZXAgLXEgIl5GSVJFQ1JB
>> "!B64TMP!" echo V0xfQVBJX0tFWT0iICIkVEdUX0RJUi8uZW52IiBcCiAgIHx8IGdyZXAgLXEgIl5GSVJFQ1JBV0xf
>> "!B64TMP!" echo QVBJX1VSTD0iICIkVEdUX0RJUi8uZW52IjsgdGhlbgogIGVjaG8gIltGQUlMXSAuZW52IHNob3Vs
>> "!B64TMP!" echo ZCBub3QgY29udGFpbiBGaXJlY3Jhd2wgYWNjb3VudCBjcmVkZW50aWFscyAoY29yZSBtb2RlKSIK
>> "!B64TMP!" echo ICBQQVNTPTAKZWxzZQogIGVjaG8gIltPS10gLmVudiBoYXMgbm8gRmlyZWNyYXdsIGFjY291bnQg
>> "!B64TMP!" echo Y3JlZGVudGlhbHMgKGNvcmUgbW9kZSkiCmZpCgojIHZlcmlmeSB0aGUgc2VjcmV0IGdvdCBpbmpl
>> "!B64TMP!" echo Y3RlZCBpbnRvIHNldHRpbmdzLnltbCAobm8gcGxhY2Vob2xkZXIgbGVmdCkKaWYgZ3JlcCAtcSAi
>> "!B64TMP!" echo X19TRUFSWE5HX1NFQ1JFVF9QTEFDRUhPTERFUl9fIiAiJFRHVF9ESVIvY29uZmlnL3NlYXJ4bmcv
>> "!B64TMP!" echo c2V0dGluZ3MueW1sIjsgdGhlbgogIGVjaG8gIltGQUlMXSBzZXR0aW5ncy55bWwgc3RpbGwgaGFz
>> "!B64TMP!" echo IHRoZSBwbGFjZWhvbGRlciAoaW5qZWN0aW9uIGZhaWxlZCkiCiAgUEFTUz0wCmVsc2UKICBlY2hv
>> "!B64TMP!" echo ICJbT0tdIHNldHRpbmdzLnltbCBubyBsb25nZXIgaGFzIHRoZSBwbGFjZWhvbGRlciAoc2VjcmV0
>> "!B64TMP!" echo IGluamVjdGVkKSIKZmkKCiMgdmVyaWZ5IC5iYXQgZmlsZXMgaGF2ZSBDUkxGIGxpbmUgZW5kaW5n
>> "!B64TMP!" echo cwpCQVRfSEFTX0NSTEY9MQpmb3IgZiBpbiBSdW4uYmF0IFN0b3AuYmF0IFVwZGF0ZS5iYXQgVW5p
>> "!B64TMP!" echo bnN0YWxsLmJhdCBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQ7IGRvCiAgaWYgISBncmVwIC1xICQn
>> "!B64TMP!" echo XHInICIkVEdUX0RJUi8kZiIgMj4vZGV2L251bGw7IHRoZW4KICAgIGVjaG8gIltGQUlMXSAkZiBk
>> "!B64TMP!" echo b2VzIG5vdCBoYXZlIENSTEYgbGluZSBlbmRpbmdzIgogICAgQkFUX0hBU19DUkxGPTAKICBmaQpk
>> "!B64TMP!" echo b25lClsgIiRCQVRfSEFTX0NSTEYiID0gMSBdICYmIGVjaG8gIltPS10gYWxsIC5iYXQgZmlsZXMg
>> "!B64TMP!" echo aGF2ZSBDUkxGIGxpbmUgZW5kaW5ncyIKCiMgLS0tIHZlcmlmeSB0aGUgc2tpbGwgd2FzIGluc3Rh
>> "!B64TMP!" echo bGxlZCBpbnRvIH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaCAtLS0tLS0tLQplY2hv
>> "!B64TMP!" echo CmVjaG8gIlNraWxsIGRpciBjb250ZW50cyAoJFNLSUxMX0RJUik6IgpmaW5kICIkU0tJTExfRElS
>> "!B64TMP!" echo IiAtdHlwZSBmIDI+L2Rldi9udWxsIHwgc29ydAoKU0tJTExfRklMRVM9IlNLSUxMLm1kIHNjcmlw
>> "!B64TMP!" echo dHMvY29uZmlnLnB5IHNjcmlwdHMvZW5zdXJlX3N0YWNrLnB5IHNjcmlwdHMvZmlyZWNyYXdsX2Fw
>> "!B64TMP!" echo aS5weSBcCiAgICAgICAgIHNjcmlwdHMvd2ViX3NlYXJjaC5weSBzY3JpcHRzL3dlYl9zY3JhcGUu
>> "!B64TMP!" echo cHkgc2NyaXB0cy93ZWJfeW91dHViZV90cmFuc2NyaXB0LnB5IFwKICAgICAgICAgc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfbWFwLnB5IHNjcmlwdHMvd2ViX2NyYXdsLnB5IHNjcmlwdHMvd2ViX2NyYXdsX3N0YXR1cy5w
>> "!B64TMP!" echo eSIKCmZvciBmIGluICRTS0lMTF9GSUxFUzsgZG8KICBpZiBbIC1zICIkU0tJTExfRElSLyRmIiBd
>> "!B64TMP!" echo OyB0aGVuCiAgICBlY2hvICIgIFtPS10gICBza2lsbDogJGYiCiAgZWxzZQogICAgZWNobyAiICBb
>> "!B64TMP!" echo RkFJTF0gc2tpbGw6ICRmIChtaXNzaW5nIG9yIGVtcHR5KSIKICAgIFBBU1M9MAogIGZpCmRvbmUK
>> "!B64TMP!" echo CiMgY29yZSBtb2RlOiB0aGUgYWNjb3VudC1nYXRlZCBzY3JpcHRzIG11c3QgYmUgYWJzZW50IGZy
>> "!B64TMP!" echo b20gdGhlIHNraWxsIGRpciB0b28KU0tJTExfQUJTRU5UPSJzY3JpcHRzL3dlYl9hZ2VudC5weSBz
>> "!B64TMP!" echo Y3JpcHRzL3dlYl9hZ2VudF9zdGF0dXMucHkgc2NyaXB0cy93ZWJfaW50ZXJhY3QucHkgXAogICAg
>> "!B64TMP!" echo ICAgICBzY3JpcHRzL3dlYl9pbnRlcmFjdF9zdG9wLnB5IHNjcmlwdHMvd2ViX3BhcnNlLnB5IFwK
>> "!B64TMP!" echo ICAgICAgICAgc2NyaXB0cy93ZWJfbW9uaXRvcl9jcmVhdGUucHkgc2NyaXB0cy93ZWJfbW9uaXRv
>> "!B64TMP!" echo cl9saXN0LnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfbW9uaXRvcl9nZXQucHkgc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfbW9uaXRvcl91cGRhdGUucHkgXAogICAgICAgICBzY3JpcHRzL3dlYl9tb25pdG9yX2RlbGV0
>> "!B64TMP!" echo ZS5weSBzY3JpcHRzL3dlYl9tb25pdG9yX3J1bi5weSBcCiAgICAgICAgIHNjcmlwdHMvd2ViX21v
>> "!B64TMP!" echo bml0b3JfY2hlY2tzLnB5IHNjcmlwdHMvd2ViX21vbml0b3JfY2hlY2sucHkgXAogICAgICAgICBz
>> "!B64TMP!" echo Y3JpcHRzL3dlYl9yZXNlYXJjaF9zZWFyY2gucHkgc2NyaXB0cy93ZWJfcmVzZWFyY2hfaW5zcGVj
>> "!B64TMP!" echo dC5weSBcCiAgICAgICAgIHNjcmlwdHMvd2ViX3Jlc2VhcmNoX3JlbGF0ZWQucHkgc2NyaXB0cy93
>> "!B64TMP!" echo ZWJfcmVzZWFyY2hfcmVhZC5weSBcCiAgICAgICAgIHNjcmlwdHMvd2ViX2dpdGh1Yl9zZWFyY2gu
>> "!B64TMP!" echo cHkgc2NyaXB0cy93ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSIKZm9yIGYgaW4gJFNLSUxMX0FCU0VO
>> "!B64TMP!" echo VDsgZG8KICBpZiBbIC1lICIkU0tJTExfRElSLyRmIiBdOyB0aGVuCiAgICBlY2hvICIgIFtGQUlM
>> "!B64TMP!" echo XSBza2lsbDogJGYgKG11c3QgTk9UIGJlIGluc3RhbGxlZCB3aXRob3V0IGEgRmlyZWNyYXdsIGFj
>> "!B64TMP!" echo Y291bnQpIgogICAgUEFTUz0wCiAgZWxzZQogICAgZWNobyAiICBbT0tdICAgc2tpbGw6ICRmIChh
>> "!B64TMP!" echo YnNlbnQgLSBjb3JlLW9ubHkgc2tpbGwsIGFzIGV4cGVjdGVkKSIKICBmaQpkb25lCmlmIFsgLWUg
>> "!B64TMP!" echo IiRTS0lMTF9ESVIvU0tJTEwtY29yZS5tZCIgXTsgdGhlbgogIGVjaG8gIiAgW0ZBSUxdIHNraWxs
>> "!B64TMP!" echo OiBTS0lMTC1jb3JlLm1kIGxlYWtlZCBpbnRvIHRoZSBpbnN0YWxsZWQgc2tpbGwiCiAgUEFTUz0w
>> "!B64TMP!" echo CmVsc2UKICBlY2hvICIgIFtPS10gICBza2lsbDogU0tJTEwtY29yZS5tZCBub3QgcHJlc2VudCAo
>> "!B64TMP!" echo YXMgZXhwZWN0ZWQpIgpmaQoKIyB2ZXJpZnkgdGhlIHNraWxsIGZpbGVzIGFyZSBpZGVudGljYWwg
>> "!B64TMP!" echo dG8gdGhlIHRhcmdldCdzIGxvY2FsLXdlYi1zZWFyY2ggY29waWVzCmZvciBmIGluICRTS0lMTF9G
>> "!B64TMP!" echo SUxFUzsgZG8KICBpZiBjbXAgLXMgIiRTS0lMTF9ESVIvJGYiICIkVEdUX0RJUi9sb2NhbC13ZWIt
>> "!B64TMP!" echo c2VhcmNoLyRmIjsgdGhlbgogICAgZWNobyAiICBbT0tdICAgc2tpbGwgZmlsZSBtYXRjaGVzIGJ1
>> "!B64TMP!" echo bmRsZWQgY29weTogJGYiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gc2tpbGwgZmlsZSBkaWZm
>> "!B64TMP!" echo ZXJzIGZyb20gYnVuZGxlZCBjb3B5OiAkZiIKICAgIFBBU1M9MAogIGZpCmRvbmUKCiMgdmVyaWZ5
>> "!B64TMP!" echo IHRoZSBpbnN0YWxsLWRpci50eHQgaGludCAoYm90aCBjb3BpZXMpIHBvaW50cyBhdCB0aGUgdGFy
>> "!B64TMP!" echo Z2V0CmlmIFsgIiQoY2F0ICIkU0tJTExfRElSL2luc3RhbGwtZGlyLnR4dCIgMj4vZGV2L251bGwp
>> "!B64TMP!" echo IiA9ICIkVEdUX0RJUiIgXTsgdGhlbgogIGVjaG8gIiAgW09LXSAgIHNraWxsIGluc3RhbGwtZGly
>> "!B64TMP!" echo LnR4dCAtPiAkVEdUX0RJUiIKZWxzZQogIGVjaG8gIiAgW0ZBSUxdIHNraWxsIGluc3RhbGwtZGly
>> "!B64TMP!" echo LnR4dCBpcyB3cm9uZzogJChjYXQgIiRTS0lMTF9ESVIvaW5zdGFsbC1kaXIudHh0IiAyPi9kZXYv
>> "!B64TMP!" echo bnVsbCkiCiAgUEFTUz0wCmZpCmlmIFsgIiQoY2F0ICIkVEdUX0RJUi9sb2NhbC13ZWItc2VhcmNo
>> "!B64TMP!" echo L2luc3RhbGwtZGlyLnR4dCIgMj4vZGV2L251bGwpIiA9ICIkVEdUX0RJUiIgXTsgdGhlbgogIGVj
>> "!B64TMP!" echo aG8gIiAgW09LXSAgIGJ1bmRsZWQgaW5zdGFsbC1kaXIudHh0IC0+ICRUR1RfRElSIgplbHNlCiAg
>> "!B64TMP!" echo ZWNobyAiICBbRkFJTF0gYnVuZGxlZCBpbnN0YWxsLWRpci50eHQgaXMgd3Jvbmc6ICQoY2F0ICIk
>> "!B64TMP!" echo VEdUX0RJUi9sb2NhbC13ZWItc2VhcmNoL2luc3RhbGwtZGlyLnR4dCIgMj4vZGV2L251bGwpIgog
>> "!B64TMP!" echo IFBBU1M9MApmaQoKIyAtLS0gdmVyaWZ5IHRoZSBoaW50IGFjdHVhbGx5IHdvcmtzOiBydW4gY29u
>> "!B64TMP!" echo ZmlnLnB5J3MgZmluZGVyIHN0YW5kYWxvbmUgLS0tLS0tCiIkUFkiIC0gIiRUR1RfRElSIiA8PCdQ
>> "!B64TMP!" echo WUVPRicKaW1wb3J0IHN5cywgb3MKZXhwZWN0ZWQgPSBzeXMuYXJndlsxXQojIFNpbXVsYXRlIHRo
>> "!B64TMP!" echo ZSBza2lsbCBiZWluZyBydW4gZnJvbSB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gv
>> "!B64TMP!" echo c2NyaXB0cwpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5leHBhbmR1c2VyKCJ+Ly5hZ2VudHMv
>> "!B64TMP!" echo c2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cyIpKQpvcy5lbnZpcm9uLnBvcCgiTE9DQUxf
>> "!B64TMP!" echo U0VBUkNIX0RJUiIsIE5vbmUpCmltcG9ydCBjb25maWcKZm91bmQgPSBjb25maWcuZmluZF9pbnN0
>> "!B64TMP!" echo YWxsX2RpcigpCmlmIGZvdW5kID09IGV4cGVjdGVkOgogICAgcHJpbnQoIiAgW09LXSAgIGNvbmZp
>> "!B64TMP!" echo Zy5maW5kX2luc3RhbGxfZGlyKCkgLT4gJXMgKGhpbnQgd29ya3MpIiAlIGZvdW5kKQplbHNlOgog
>> "!B64TMP!" echo ICAgcHJpbnQoIiAgW0ZBSUxdIGNvbmZpZy5maW5kX2luc3RhbGxfZGlyKCkgLT4gJXIgKGV4cGVj
>> "!B64TMP!" echo dGVkICVyKSIgJSAoZm91bmQsIGV4cGVjdGVkKSkKICAgIHN5cy5leGl0KDEpCmVwcyA9IGNvbmZp
>> "!B64TMP!" echo Zy5lbmRwb2ludHMoZm91bmQpCmlmIGVwcyA9PSB7InNlYXJ4bmciOiAiaHR0cDovL2xvY2FsaG9z
>> "!B64TMP!" echo dDo5OTkwIiwgImZpcmVjcmF3bCI6ICJodHRwOi8vbG9jYWxob3N0Ojk5OTEifToKICAgIHByaW50
>> "!B64TMP!" echo KCIgIFtPS10gICBlbmRwb2ludHMgcmVhZCBmcm9tIC5lbnY6ICVzIiAlIGVwcykKZWxzZToKICAg
>> "!B64TMP!" echo IHByaW50KCIgIFtGQUlMXSBlbmRwb2ludHMgd3Jvbmc6ICVzIiAlIGVwcykKICAgIHN5cy5leGl0
>> "!B64TMP!" echo KDEpClBZRU9GClsgJD8gPSAwIF0gfHwgUEFTUz0wCgojIC0tLSB2ZXJpZnkgd2ViX3NlYXJjaC5w
>> "!B64TMP!" echo eSAvIHdlYl9zY3JhcGUucHkgcmVzb2x2ZSB0aGUgZW5kcG9pbnRzIC0tLS0tLS0tLS0tLS0KIiRQ
>> "!B64TMP!" echo WSIgLSA8PCdQWUVPRicKaW1wb3J0IHN5cywgb3MKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGgu
>> "!B64TMP!" echo ZXhwYW5kdXNlcigifi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMiKSkK
>> "!B64TMP!" echo aW1wb3J0IHdlYl9zZWFyY2gKaWYgd2ViX3NlYXJjaC5CQVNFLmVuZHN3aXRoKCI6OTk5MC9zZWFy
>> "!B64TMP!" echo Y2giKToKICAgIHByaW50KCIgIFtPS10gICB3ZWJfc2VhcmNoLkJBU0UgPSAlcyIgJSB3ZWJfc2Vh
>> "!B64TMP!" echo cmNoLkJBU0UpCmVsc2U6CiAgICBwcmludCgiICBbRkFJTF0gd2ViX3NlYXJjaC5CQVNFID0gJXMi
>> "!B64TMP!" echo ICUgd2ViX3NlYXJjaC5CQVNFKQogICAgc3lzLmV4aXQoMSkKaW1wb3J0IHdlYl9zY3JhcGUKaWYg
>> "!B64TMP!" echo d2ViX3NjcmFwZS5FTkRQT0lOVC5lbmRzd2l0aCgiOjk5OTEvdjEvc2NyYXBlIik6CiAgICBwcmlu
>> "!B64TMP!" echo dCgiICBbT0tdICAgd2ViX3NjcmFwZS5FTkRQT0lOVCA9ICVzIiAlIHdlYl9zY3JhcGUuRU5EUE9J
>> "!B64TMP!" echo TlQpCmVsc2U6CiAgICBwcmludCgiICBbRkFJTF0gd2ViX3NjcmFwZS5FTkRQT0lOVCA9ICVzIiAl
>> "!B64TMP!" echo IHdlYl9zY3JhcGUuRU5EUE9JTlQpCiAgICBzeXMuZXhpdCgxKQpQWUVPRgpbICQ/ID0gMCBdIHx8
>> "!B64TMP!" echo IFBBU1M9MAoKIyAtLS0gdmVyaWZ5IHRoZSBjb3JlIEZpcmVjcmF3bCB0b29sIHNjcmlwdHMgcmVz
>> "!B64TMP!" echo b2x2ZSB0aGUgTE9DQUwgZW5kcG9pbnRzIC0tLS0tLQoiJFBZIiAtIDw8J1BZRU9GJwppbXBvcnQg
>> "!B64TMP!" echo c3lzLCBvcwpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5leHBhbmR1c2VyKCJ+Ly5hZ2VudHMv
>> "!B64TMP!" echo c2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cyIpKQppbXBvcnQgZmlyZWNyYXdsX2FwaSBh
>> "!B64TMP!" echo cyBmYwppZiBmYy5iYXNlX3VybCgpLmVuZHN3aXRoKCI6OTk5MSIpIGFuZCBmYy5pc19sb2NhbCgp
>> "!B64TMP!" echo OgogICAgcHJpbnQoIiAgW09LXSAgIGZpcmVjcmF3bF9hcGkuYmFzZV91cmwgPSAlcyAobG9jYWwg
>> "!B64TMP!" echo c3RhY2spIiAlIGZjLmJhc2VfdXJsKCkpCmVsc2U6CiAgICBwcmludCgiICBbRkFJTF0gZmlyZWNy
>> "!B64TMP!" echo YXdsX2FwaS5iYXNlX3VybCA9ICVzIiAlIGZjLmJhc2VfdXJsKCkpCiAgICBzeXMuZXhpdCgxKQpp
>> "!B64TMP!" echo ZiBmYy5hdXRoX2hlYWRlcnMoKS5nZXQoIkF1dGhvcml6YXRpb24iKSBpcyBOb25lOgogICAgcHJp
>> "!B64TMP!" echo bnQoIiAgW09LXSAgIG5vIEJlYXJlciBrZXkgaW4gY29yZSBtb2RlIChsb2NhbCBzdGFjaywgbm8g
>> "!B64TMP!" echo YWNjb3VudCkiKQplbHNlOgogICAgcHJpbnQoIiAgW0ZBSUxdIHVuZXhwZWN0ZWQgQXV0aG9yaXph
>> "!B64TMP!" echo dGlvbiBoZWFkZXIgaW4gY29yZSBtb2RlIikKICAgIHN5cy5leGl0KDEpCmNoZWNrcyA9IFsKICAg
>> "!B64TMP!" echo ICgid2ViX21hcCIsICAgICAgICAgICIvdjEvbWFwIiksCiAgICAoIndlYl9jcmF3bCIsICAgICAg
>> "!B64TMP!" echo ICAiL3YxL2NyYXdsIiksCiAgICAoIndlYl9jcmF3bF9zdGF0dXMiLCAiL3YxL2NyYXdsIiksCl0K
>> "!B64TMP!" echo Zm9yIG5hbWUsIHN1ZmZpeCBpbiBjaGVja3M6CiAgICBtb2QgPSBfX2ltcG9ydF9fKG5hbWUpCiAg
>> "!B64TMP!" echo ICBlbmRwb2ludCA9IG1vZC5FTkRQT0lOVAogICAgaWYgZW5kcG9pbnQuZW5kc3dpdGgoIjo5OTkx
>> "!B64TMP!" echo IiArIHN1ZmZpeCk6CiAgICAgICAgcHJpbnQoIiAgW09LXSAgICVzLkVORFBPSU5UID0gJXMiICUg
>> "!B64TMP!" echo KG5hbWUsIGVuZHBvaW50KSkKICAgIGVsc2U6CiAgICAgICAgcHJpbnQoIiAgW0ZBSUxdICVzLkVO
>> "!B64TMP!" echo RFBPSU5UID0gJXMgKGV4cGVjdGVkIHN1ZmZpeCAlcykiICUgKG5hbWUsIGVuZHBvaW50LCBzdWZm
>> "!B64TMP!" echo aXgpKQogICAgICAgIHN5cy5leGl0KDEpClBZRU9GClsgJD8gPSAwIF0gfHwgUEFTUz0wCgojIC0t
>> "!B64TMP!" echo LSBzZWxmLWhlYWwgdGVzdDogc2NyaXB0cyBhdXRvLXN0YXJ0IGEgZG93biBzdGFjayAtLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLQplY2hvCmVjaG8gIj09PT09IHNlbGYtaGVhbCB0ZXN0OiB3ZWJfc2Vh
>> "!B64TMP!" echo cmNoIC8gd2ViX3NjcmFwZSBzdGFydCBhIGRvd24gc3RhY2sgPT09PT0iCgpwb3J0c19mcmVlKCkg
>> "!B64TMP!" echo ewogICIkUFkiIC0gPDwnUFlLJwppbXBvcnQgc29ja2V0LCBzeXMKZm9yIHBvcnQgaW4gKDk5OTAs
>> "!B64TMP!" echo IDk5OTEpOgogICAgcyA9IHNvY2tldC5zb2NrZXQoKTsgcy5zZXR0aW1lb3V0KDAuMykKICAgIGlm
>> "!B64TMP!" echo IHMuY29ubmVjdF9leCgoIjEyNy4wLjAuMSIsIHBvcnQpKSA9PSAwOgogICAgICAgIHN5cy5leGl0
>> "!B64TMP!" echo KDEpCiAgICBzLmNsb3NlKCkKc3lzLmV4aXQoMCkKUFlLCn0KCmlmIHBvcnRzX2ZyZWU7IHRoZW4K
>> "!B64TMP!" echo ICAjIGZha2Ugc3RhY2s6IGFuc3dlcnMgU2VhclhORyBKU09OIG9uICQxIGFuZCBGaXJlY3Jhd2wg
>> "!B64TMP!" echo c2NyYXBlIEpTT04gb24gJDIKICBjYXQgPiAiJFRFU1RST09UL2Zha2Vfc3RhY2sucHkiIDw8J0ZB
>> "!B64TMP!" echo S0UnCmltcG9ydCBqc29uLCBvcywgc3lzLCB0aHJlYWRpbmcsIHRpbWUKZnJvbSBodHRwLnNlcnZl
>> "!B64TMP!" echo ciBpbXBvcnQgQmFzZUhUVFBSZXF1ZXN0SGFuZGxlciwgSFRUUFNlcnZlcgpmcm9tIHVybGxpYi5w
>> "!B64TMP!" echo YXJzZSBpbXBvcnQgdXJscGFyc2UsIHBhcnNlX3FzCgpTRUFSWF9QT1JULCBGQ19QT1JULCBQSURG
>> "!B64TMP!" echo SUxFID0gaW50KHN5cy5hcmd2WzFdKSwgaW50KHN5cy5hcmd2WzJdKSwgc3lzLmFyZ3ZbM10Kd2l0
>> "!B64TMP!" echo aCBvcGVuKFBJREZJTEUsICJ3IikgYXMgZmg6CiAgICBmaC53cml0ZShzdHIob3MuZ2V0cGlkKCkp
>> "!B64TMP!" echo KQoKY2xhc3MgU2VhcngoQmFzZUhUVFBSZXF1ZXN0SGFuZGxlcik6CiAgICBkZWYgZG9fR0VUKHNl
>> "!B64TMP!" echo bGYpOgogICAgICAgIHEgPSBwYXJzZV9xcyh1cmxwYXJzZShzZWxmLnBhdGgpLnF1ZXJ5KS5nZXQo
>> "!B64TMP!" echo InEiLCBbIiJdKVswXQogICAgICAgIGJvZHkgPSBqc29uLmR1bXBzKHsicmVzdWx0cyI6IFt7CiAg
>> "!B64TMP!" echo ICAgICAgICAgICJ0aXRsZSI6ICJGQUtFIFJFU1VMVCBmb3IgIiArIHEsCiAgICAgICAgICAgICJ1
>> "!B64TMP!" echo cmwiOiAiaHR0cHM6Ly9leGFtcGxlLmNvbS9mYWtlIiwKICAgICAgICAgICAgImNvbnRlbnQiOiAi
>> "!B64TMP!" echo ZmFrZSBzbmlwcGV0In1dfSkuZW5jb2RlKCkKICAgICAgICBzZWxmLnNlbmRfcmVzcG9uc2UoMjAw
>> "!B64TMP!" echo KQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQtVHlwZSIsICJhcHBsaWNhdGlvbi9q
>> "!B64TMP!" echo c29uIikKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LUxlbmd0aCIsIHN0cihsZW4o
>> "!B64TMP!" echo Ym9keSkpKQogICAgICAgIHNlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgIHNlbGYud2ZpbGUud3Jp
>> "!B64TMP!" echo dGUoYm9keSkKICAgIGRlZiBsb2dfbWVzc2FnZShzZWxmLCAqYSk6IHBhc3MKCmNsYXNzIEZjKEJh
>> "!B64TMP!" echo c2VIVFRQUmVxdWVzdEhhbmRsZXIpOgogICAgZGVmIGRvX1BPU1Qoc2VsZik6CiAgICAgICAgYm9k
>> "!B64TMP!" echo eSA9IGpzb24uZHVtcHMoeyJkYXRhIjogeyJtYXJrZG93biI6ICIjIEZBS0UgTUFSS0RPV05cbmhl
>> "!B64TMP!" echo bGxvIGZyb20gZmFrZSBmaXJlY3Jhd2wifX0pLmVuY29kZSgpCiAgICAgICAgc2VsZi5zZW5kX3Jl
>> "!B64TMP!" echo c3BvbnNlKDIwMCkKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LVR5cGUiLCAiYXBw
>> "!B64TMP!" echo bGljYXRpb24vanNvbiIpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1MZW5ndGgi
>> "!B64TMP!" echo LCBzdHIobGVuKGJvZHkpKSkKICAgICAgICBzZWxmLmVuZF9oZWFkZXJzKCkKICAgICAgICBzZWxm
>> "!B64TMP!" echo LndmaWxlLndyaXRlKGJvZHkpCiAgICBkZWYgbG9nX21lc3NhZ2Uoc2VsZiwgKmEpOiBwYXNzCgpm
>> "!B64TMP!" echo b3IgaGFuZGxlciwgcG9ydCBpbiAoKFNlYXJ4LCBTRUFSWF9QT1JUKSwgKEZjLCBGQ19QT1JUKSk6
>> "!B64TMP!" echo CiAgICB0aHJlYWRpbmcuVGhyZWFkKHRhcmdldD1IVFRQU2VydmVyKCgiMTI3LjAuMC4xIiwgcG9y
>> "!B64TMP!" echo dCksIGhhbmRsZXIpLnNlcnZlX2ZvcmV2ZXIsCiAgICAgICAgICAgICAgICAgICAgIGRhZW1vbj1U
>> "!B64TMP!" echo cnVlKS5zdGFydCgpCndoaWxlIFRydWU6CiAgICB0aW1lLnNsZWVwKDM2MDApCkZBS0UKCiAgRkFL
>> "!B64TMP!" echo RV9QSURGSUxFPSIkVEVTVFJPT1QvZmFrZV9zdGFjay5waWQiCiAga2lsbF9mYWtlX3N0YWNrKCkg
>> "!B64TMP!" echo ewogICAgaWYgWyAtZiAiJEZBS0VfUElERklMRSIgXTsgdGhlbgogICAgICBraWxsICIkKGNhdCAi
>> "!B64TMP!" echo JEZBS0VfUElERklMRSIgMj4vZGV2L251bGwpIiAyPi9kZXYvbnVsbAogICAgICBybSAtZiAiJEZB
>> "!B64TMP!" echo S0VfUElERklMRSIKICAgIGZpCiAgICBmb3IgXyBpbiAxIDIgMyA0IDUgNiA3IDggOSAxMDsgZG8K
>> "!B64TMP!" echo ICAgICAgcG9ydHNfZnJlZSAmJiByZXR1cm4gMAogICAgICBzbGVlcCAwLjUKICAgIGRvbmUKICAg
>> "!B64TMP!" echo IHJldHVybiAxCiAgfQoKICAjIG1vY2sgZG9ja2VyICMyOiBgY29tcG9zZSB1cCAtZGAgcmVhZHMg
>> "!B64TMP!" echo dGhlIHBvcnRzIGZyb20gLi8uZW52IGFuZCBzdGFydHMKICAjIHRoZSBmYWtlIHN0YWNrIChzbyBz
>> "!B64TMP!" echo ZWxmLWhlYWwgYWN0dWFsbHkgYnJpbmdzIHRoZSBlbmRwb2ludHMgdXApCiAgbWtkaXIgLXAgIiRU
>> "!B64TMP!" echo RVNUUk9PVC9iaW4yIgogIGNhdCA+ICIkVEVTVFJPT1QvYmluMi9kb2NrZXIiIDw8J01PQ0syJwoj
>> "!B64TMP!" echo IS91c3IvYmluL2VudiBiYXNoCmNhc2UgIiQxIiBpbgogIGluZm8pIGV4aXQgMCA7OwogIGNvbXBv
>> "!B64TMP!" echo c2UpCiAgICBjYXNlICIkMiIgaW4KICAgICAgdmVyc2lvbikgZWNobyAiRG9ja2VyIENvbXBvc2Ug
>> "!B64TMP!" echo dmVyc2lvbiB2Mi4wLjAtdGVzdCI7IGV4aXQgMCA7OwogICAgICB1cCkKICAgICAgICBTRUFSWE5H
>> "!B64TMP!" echo X1BPUlQ9JChncmVwIC1FICdeU0VBUlhOR19QT1JUPScgLmVudiB8IGN1dCAtZD0gLWYyKQogICAg
>> "!B64TMP!" echo ICAgIEZJUkVDUkFXTF9QT1JUPSQoZ3JlcCAtRSAnXkZJUkVDUkFXTF9QT1JUPScgLmVudiB8IGN1
>> "!B64TMP!" echo dCAtZD0gLWYyKQogICAgICAgIG5vaHVwICIkRkFLRV9QWSIgIiRGQUtFX1NUQUNLIiAiJFNFQVJY
>> "!B64TMP!" echo TkdfUE9SVCIgIiRGSVJFQ1JBV0xfUE9SVCIgIiRGQUtFX1BJREZJTEUiID4vZGV2L251bGwgMj4m
>> "!B64TMP!" echo MSAmCiAgICAgICAgZWNobyAiW21vY2tdIGNvbXBvc2UgdXAgb2sgKGZha2Ugc3RhY2sgc3RhcnRl
>> "!B64TMP!" echo ZCkiCiAgICAgICAgZXhpdCAwIDs7CiAgICAgICopIGV4aXQgMCA7OwogICAgZXNhYyA7OwogICop
>> "!B64TMP!" echo IGV4aXQgMCA7Owplc2FjCk1PQ0syCiAgY2htb2QgK3ggIiRURVNUUk9PVC9iaW4yL2RvY2tlciIK
>> "!B64TMP!" echo CiAgIyBtb2NrIGRvY2tlciAjMzogYGNvbXBvc2UgdXAgLWRgIHN1Y2NlZWRzIGJ1dCBzdGFydHMg
>> "!B64TMP!" echo Tk9USElORyAoZmFpbHVyZSBwYXRoKQogIG1rZGlyIC1wICIkVEVTVFJPT1QvYmluMyIKICBjYXQg
>> "!B64TMP!" echo PiAiJFRFU1RST09UL2JpbjMvZG9ja2VyIiA8PCdNT0NLMycKIyEvdXNyL2Jpbi9lbnYgYmFzaApj
>> "!B64TMP!" echo YXNlICIkMSIgaW4KICBpbmZvKSBleGl0IDAgOzsKICBjb21wb3NlKQogICAgY2FzZSAiJDIiIGlu
>> "!B64TMP!" echo CiAgICAgIHZlcnNpb24pIGVjaG8gIkRvY2tlciBDb21wb3NlIHZlcnNpb24gdjIuMC4wLXRlc3Qi
>> "!B64TMP!" echo OyBleGl0IDAgOzsKICAgICAgdXApIGVjaG8gIlttb2NrXSBjb21wb3NlIHVwIG9rIChub3RoaW5n
>> "!B64TMP!" echo IGFjdHVhbGx5IHN0YXJ0ZWQpIjsgZXhpdCAwIDs7CiAgICAgICopIGV4aXQgMCA7OwogICAgZXNh
>> "!B64TMP!" echo YyA7OwogICopIGV4aXQgMCA7Owplc2FjCk1PQ0szCiAgY2htb2QgK3ggIiRURVNUUk9PVC9iaW4z
>> "!B64TMP!" echo L2RvY2tlciIKCiAgSEVBTF9FTlY9IkZBS0VfUFk9JFBZIEZBS0VfU1RBQ0s9JFRFU1RST09UL2Zh
>> "!B64TMP!" echo a2Vfc3RhY2sucHkgRkFLRV9QSURGSUxFPSRGQUtFX1BJREZJTEUgTE9DQUxfU0VBUkNIX0RJUj0k
>> "!B64TMP!" echo VEdUX0RJUiIKCiAgIyBQaGFzZSBBIC0gZmFzdCBwYXRoOiBzdGFjayBhbHJlYWR5IHVwIC0+IHN0
>> "!B64TMP!" echo cmFpZ2h0IHRvIHJlc3VsdHMsIG5vIGJvb3QKICBub2h1cCAiJFBZIiAiJFRFU1RST09UL2Zha2Vf
>> "!B64TMP!" echo c3RhY2sucHkiIDk5OTAgOTk5MSAiJEZBS0VfUElERklMRSIgPi9kZXYvbnVsbCAyPiYxICYKICBz
>> "!B64TMP!" echo bGVlcCAxCiAgaWYgZW52ICRIRUFMX0VOViAiJFBZIiAiJFNLSUxMX0RJUi9zY3JpcHRzL3dlYl9z
>> "!B64TMP!" echo ZWFyY2gucHkiICJmYXN0IHBhdGgiIFwKICAgICAgID4gIiRURVNUUk9PVC9oZWFsQS5sb2ciIDI+
>> "!B64TMP!" echo JjEgXAogICAgICYmIGdyZXAgLXEgIkZBS0UgUkVTVUxUIGZvciBmYXN0IHBhdGgiICIkVEVTVFJP
>> "!B64TMP!" echo T1QvaGVhbEEubG9nIiBcCiAgICAgJiYgISBncmVwIC1xICJzdGFydGluZyBpdCBhdXRvbWF0aWNh
>> "!B64TMP!" echo bGx5IiAiJFRFU1RST09UL2hlYWxBLmxvZyI7IHRoZW4KICAgIGVjaG8gIiAgW09LXSAgIGZhc3Qg
>> "!B64TMP!" echo cGF0aDogc2VhcmNoIHdvcmtzIHdpdGggdGhlIHN0YWNrIGFscmVhZHkgdXAgKG5vIGJvb3QpIgog
>> "!B64TMP!" echo IGVsc2UKICAgIGVjaG8gIiAgW0ZBSUxdIGZhc3QtcGF0aCBzZWFyY2giOyBjYXQgIiRURVNUUk9P
>> "!B64TMP!" echo VC9oZWFsQS5sb2ciOyBQQVNTPTAKICBmaQoKICAjIFBoYXNlIEIgLSBzZWxmLWhlYWw6IHN0YWNr
>> "!B64TMP!" echo IGRvd24gLT4gYm9vdCAobW9jayBjb21wb3NlKSAtPiByZXRyeSAtPiByZXN1bHRzCiAga2lsbF9m
>> "!B64TMP!" echo YWtlX3N0YWNrCiAgaWYgZW52ICRIRUFMX0VOViBQQVRIPSIkVEVTVFJPT1QvYmluMjokUEFUSCIg
>> "!B64TMP!" echo XAogICAgICAgIiRQWSIgIiRTS0lMTF9ESVIvc2NyaXB0cy93ZWJfc2VhcmNoLnB5IiAic2VsZmhl
>> "!B64TMP!" echo YWwgc2VhcmNoIiBcCiAgICAgICA+ICIkVEVTVFJPT1QvaGVhbEIubG9nIiAyPiYxIFwKICAgICAm
>> "!B64TMP!" echo JiBncmVwIC1xICJzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IiAiJFRFU1RST09UL2hlYWxCLmxv
>> "!B64TMP!" echo ZyIgXAogICAgICYmIGdyZXAgLXEgIkZBS0UgUkVTVUxUIGZvciBzZWxmaGVhbCBzZWFyY2giICIk
>> "!B64TMP!" echo VEVTVFJPT1QvaGVhbEIubG9nIjsgdGhlbgogICAgZWNobyAiICBbT0tdICAgc2VsZi1oZWFsOiB3
>> "!B64TMP!" echo ZWJfc2VhcmNoIGJvb3RlZCB0aGUgZG93biBzdGFjayBhbmQgcmV0cmllZCIKICBlbHNlCiAgICBl
>> "!B64TMP!" echo Y2hvICIgIFtGQUlMXSB3ZWJfc2VhcmNoIHNlbGYtaGVhbCI7IGNhdCAiJFRFU1RST09UL2hlYWxC
>> "!B64TMP!" echo LmxvZyI7IFBBU1M9MAogIGZpCgogICMgUGhhc2UgQjIgLSBzZWxmLWhlYWwgZm9yIHRoZSBzY3Jh
>> "!B64TMP!" echo cGVyCiAga2lsbF9mYWtlX3N0YWNrCiAgaWYgZW52ICRIRUFMX0VOViBQQVRIPSIkVEVTVFJPT1Qv
>> "!B64TMP!" echo YmluMjokUEFUSCIgXAogICAgICAgIiRQWSIgIiRTS0lMTF9ESVIvc2NyaXB0cy93ZWJfc2NyYXBl
>> "!B64TMP!" echo LnB5IiAiaHR0cHM6Ly9leGFtcGxlLmNvbS9hcnRpY2xlIiBcCiAgICAgICA+ICIkVEVTVFJPT1Qv
>> "!B64TMP!" echo aGVhbEIyLmxvZyIgMj4mMSBcCiAgICAgJiYgZ3JlcCAtcSAic3RhcnRpbmcgaXQgYXV0b21hdGlj
>> "!B64TMP!" echo YWxseSIgIiRURVNUUk9PVC9oZWFsQjIubG9nIiBcCiAgICAgJiYgZ3JlcCAtcSAiRkFLRSBNQVJL
>> "!B64TMP!" echo RE9XTiIgIiRURVNUUk9PVC9oZWFsQjIubG9nIjsgdGhlbgogICAgZWNobyAiICBbT0tdICAgc2Vs
>> "!B64TMP!" echo Zi1oZWFsOiB3ZWJfc2NyYXBlIGJvb3RlZCB0aGUgZG93biBzdGFjayBhbmQgcmV0cmllZCIKICBl
>> "!B64TMP!" echo bHNlCiAgICBlY2hvICIgIFtGQUlMXSB3ZWJfc2NyYXBlIHNlbGYtaGVhbCI7IGNhdCAiJFRFU1RS
>> "!B64TMP!" echo T09UL2hlYWxCMi5sb2ciOyBQQVNTPTAKICBmaQoKICAjIFBoYXNlIEMgLSBmYWlsdXJlOiBzdGFj
>> "!B64TMP!" echo ayBjYW5ub3QgY29tZSB1cCAtPiBjbGVhciBndWlkYW5jZSwgZXhpdCAxCiAga2lsbF9mYWtlX3N0
>> "!B64TMP!" echo YWNrCiAgaWYgZW52ICRIRUFMX0VOViBQQVRIPSIkVEVTVFJPT1QvYmluMzokUEFUSCIgTE9DQUxf
>> "!B64TMP!" echo U0VBUkNIX1JFQURZX1RJTUVPVVQ9MiBcCiAgICAgICAiJFBZIiAiJFNLSUxMX0RJUi9zY3JpcHRz
>> "!B64TMP!" echo L3dlYl9zZWFyY2gucHkiICJkb29tZWQiIFwKICAgICAgID4gIiRURVNUUk9PVC9oZWFsQy5sb2ci
>> "!B64TMP!" echo IDI+JjE7IHRoZW4KICAgIGVjaG8gIiAgW0ZBSUxdIHNlbGYtaGVhbCBmYWlsdXJlIHBhdGggc2hv
>> "!B64TMP!" echo dWxkIGV4aXQgbm9uLXplcm8iOyBQQVNTPTAKICBlbGlmIGdyZXAgLXEgImNvdWxkIG5vdCBiZSBz
>> "!B64TMP!" echo dGFydGVkIiAiJFRFU1RST09UL2hlYWxDLmxvZyIgXAogICAgICAgJiYgZ3JlcCAtcSAiZGlkIG5v
>> "!B64TMP!" echo dCBiZWNvbWUgcmVhZHkiICIkVEVTVFJPT1QvaGVhbEMubG9nIjsgdGhlbgogICAgZWNobyAiICBb
>> "!B64TMP!" echo T0tdICAgc2VsZi1oZWFsIGZhaWx1cmU6IGNsZWFyIGd1aWRhbmNlLCBub24temVybyBleGl0Igog
>> "!B64TMP!" echo IGVsc2UKICAgIGVjaG8gIiAgW0ZBSUxdIHNlbGYtaGVhbCBmYWlsdXJlIG1lc3NhZ2UgbWlzc2lu
>> "!B64TMP!" echo ZyI7IGNhdCAiJFRFU1RST09UL2hlYWxDLmxvZyI7IFBBU1M9MAogIGZpCiAga2lsbF9mYWtlX3N0
>> "!B64TMP!" echo YWNrCmVsc2UKICBlY2hvICIgIFtXQVJOXSBwb3J0cyA5OTkwLzk5OTEgYXJlIGluIHVzZSAtIHNr
>> "!B64TMP!" echo aXBwaW5nIHRoZSBzZWxmLWhlYWwgdGVzdCIKZmkKCiMgLS0tIGFjY291bnQtbW9kZSBpbnN0YWxs
>> "!B64TMP!" echo OiBhIEZpcmVjcmF3bCBhY2NvdW50IGluc3RhbGxzIGFsbCAyNSB0b29scyAtLS0tLS0KZWNobwpl
>> "!B64TMP!" echo Y2hvICI9PT09PSBhY2NvdW50LW1vZGUgaW5zdGFsbDogZmFrZSBGaXJlY3Jhd2wgYWNjb3VudCAt
>> "!B64TMP!" echo PiBhbGwgMjUgdG9vbHMgPT09PT0iCgpUR1QzPSIkVEVTVFJPT1QvdGFyZ2V0MyIKIyBhbnN3ZXJz
>> "!B64TMP!" echo OiB0YXJnZXQsIHNlYXJ4bmcgcG9ydCwgZmlyZWNyYXdsIHBvcnQsIExMTT8gLT4gbiwKIyAgICAg
>> "!B64TMP!" echo ICAgICBhY2NvdW50PyAtPiB5LCBrZXksIFVSTCAoRW50ZXIgPSBkZWZhdWx0KSwgY29uZmlybSAt
>> "!B64TMP!" echo PiB5CnByaW50ZiAnJXNcbiVzXG4lc1xuJXNcbiVzXG4lc1xuJXNcbiVzXG4nIFwKICAiJFRHVDMi
>> "!B64TMP!" echo ICIiICIiICJuIiAieSIgImZjLWUyZS10ZXN0LWtleS0xMjMiICIiICJ5IiBcCiAgfCAiJFNSQ19E
>> "!B64TMP!" echo SVIvaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giID4gIiRURVNUUk9PVC9pbnN0My5sb2ciIDI+JjEK
>> "!B64TMP!" echo UkMzPSQ/CmVjaG8gIkluc3RhbGxlciBleGl0IGNvZGU6ICRSQzMiCnRhaWwgLTIwICIkVEVTVFJP
>> "!B64TMP!" echo T1QvaW5zdDMubG9nIgplY2hvICItLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSIKCmlm
>> "!B64TMP!" echo IFsgIiRSQzMiID0gMCBdIFwKICAgJiYgZ3JlcCAtcSAiSW5zdGFsbGluZyB0aGUgbG9jYWwtd2Vi
>> "!B64TMP!" echo LXNlYXJjaCBhZ2VudCBza2lsbCIgIiRURVNUUk9PVC9pbnN0My5sb2ciIFwKICAgJiYgISBncmVw
>> "!B64TMP!" echo IC1xICJjb3JlLW9ubHkiICIkVEVTVFJPT1QvaW5zdDMubG9nIjsgdGhlbgogIGVjaG8gIiAgW09L
>> "!B64TMP!" echo XSAgIGFjY291bnQtbW9kZSBpbnN0YWxsIGNvbXBsZXRlZCAobm8gY29yZS1vbmx5IHRyaW0pIgpl
>> "!B64TMP!" echo bHNlCiAgZWNobyAiICBbRkFJTF0gYWNjb3VudC1tb2RlIGluc3RhbGwiOyBQQVNTPTAKZmkKCmlm
>> "!B64TMP!" echo IGdyZXAgLXEgIl5GSVJFQ1JBV0xfQVBJX1VSTD1odHRwczovL2FwaS5maXJlY3Jhd2wuZGV2JCIg
>> "!B64TMP!" echo IiRUR1QzLy5lbnYiIFwKICAgJiYgZ3JlcCAtcSAiXkZJUkVDUkFXTF9BUElfS0VZPWZjLWUyZS10
>> "!B64TMP!" echo ZXN0LWtleS0xMjMkIiAiJFRHVDMvLmVudiI7IHRoZW4KICBlY2hvICIgIFtPS10gICAuZW52IGhv
>> "!B64TMP!" echo bGRzIHRoZSBhY2NvdW50IGNyZWRlbnRpYWxzIgplbHNlCiAgZWNobyAiICBbRkFJTF0gLmVudiBp
>> "!B64TMP!" echo cyBtaXNzaW5nIHRoZSBhY2NvdW50IGNyZWRlbnRpYWxzIjsgUEFTUz0wCmZpCgppZiBncmVwIC1x
>> "!B64TMP!" echo ICJ3ZWJfbW9uaXRvcl9jcmVhdGUiICIkU0tJTExfRElSL1NLSUxMLm1kIiBcCiAgICYmICEgZ3Jl
>> "!B64TMP!" echo cCAtcSAiNiB0b29sczogc2VhcmNoLCBzY3JhcGUsIG1hcCwgY3Jhd2wsIGNyYXdsIHN0YXR1cywg
>> "!B64TMP!" echo WW91VHViZSIgIiRTS0lMTF9ESVIvU0tJTEwubWQiIFwKICAgJiYgWyAhIC1lICIkU0tJTExfRElS
>> "!B64TMP!" echo L1NLSUxMLWNvcmUubWQiIF0gXAogICAmJiBbICEgLWUgIiRUR1QzL2xvY2FsLXdlYi1zZWFyY2gv
>> "!B64TMP!" echo U0tJTEwtY29yZS5tZCIgXTsgdGhlbgogIGVjaG8gIiAgW09LXSAgIFNLSUxMLm1kIGlzIHRoZSBm
>> "!B64TMP!" echo dWxsIDI1LXRvb2wgdmFyaWFudCAoU0tJTEwtY29yZS5tZCBjbGVhbmVkIHVwKSIKZWxzZQogIGVj
>> "!B64TMP!" echo aG8gIiAgW0ZBSUxdIFNLSUxMLm1kIHZhcmlhbnQgd3JvbmcgaW4gYWNjb3VudCBtb2RlIjsgUEFT
>> "!B64TMP!" echo Uz0wCmZpCgpBTExfU0tJTExfRklMRVM9IlNLSUxMLm1kIHNjcmlwdHMvY29uZmlnLnB5IHNjcmlw
>> "!B64TMP!" echo dHMvZW5zdXJlX3N0YWNrLnB5IHNjcmlwdHMvZmlyZWNyYXdsX2FwaS5weSBcCiAgICAgICAgIHNj
>> "!B64TMP!" echo cmlwdHMvd2ViX3NlYXJjaC5weSBzY3JpcHRzL3dlYl9zY3JhcGUucHkgc2NyaXB0cy93ZWJfeW91
>> "!B64TMP!" echo dHViZV90cmFuc2NyaXB0LnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfbWFwLnB5IFwKICAgICAg
>> "!B64TMP!" echo ICAgc2NyaXB0cy93ZWJfY3Jhd2wucHkgc2NyaXB0cy93ZWJfY3Jhd2xfc3RhdHVzLnB5IHNjcmlw
>> "!B64TMP!" echo dHMvd2ViX2FnZW50LnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfYWdlbnRfc3RhdHVzLnB5IHNj
>> "!B64TMP!" echo cmlwdHMvd2ViX2ludGVyYWN0LnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfaW50ZXJhY3Rfc3Rv
>> "!B64TMP!" echo cC5weSBzY3JpcHRzL3dlYl9wYXJzZS5weSBcCiAgICAgICAgIHNjcmlwdHMvd2ViX21vbml0b3Jf
>> "!B64TMP!" echo Y3JlYXRlLnB5IHNjcmlwdHMvd2ViX21vbml0b3JfbGlzdC5weSBcCiAgICAgICAgIHNjcmlwdHMv
>> "!B64TMP!" echo d2ViX21vbml0b3JfZ2V0LnB5IHNjcmlwdHMvd2ViX21vbml0b3JfdXBkYXRlLnB5IFwKICAgICAg
>> "!B64TMP!" echo ICAgc2NyaXB0cy93ZWJfbW9uaXRvcl9kZWxldGUucHkgc2NyaXB0cy93ZWJfbW9uaXRvcl9ydW4u
>> "!B64TMP!" echo cHkgXAogICAgICAgICBzY3JpcHRzL3dlYl9tb25pdG9yX2NoZWNrcy5weSBzY3JpcHRzL3dlYl9t
>> "!B64TMP!" echo b25pdG9yX2NoZWNrLnB5IFwKICAgICAgICAgc2NyaXB0cy93ZWJfcmVzZWFyY2hfc2VhcmNoLnB5
>> "!B64TMP!" echo IHNjcmlwdHMvd2ViX3Jlc2VhcmNoX2luc3BlY3QucHkgXAogICAgICAgICBzY3JpcHRzL3dlYl9y
>> "!B64TMP!" echo ZXNlYXJjaF9yZWxhdGVkLnB5IHNjcmlwdHMvd2ViX3Jlc2VhcmNoX3JlYWQucHkgXAogICAgICAg
>> "!B64TMP!" echo ICBzY3JpcHRzL3dlYl9naXRodWJfc2VhcmNoLnB5IHNjcmlwdHMvd2ViX2RldmVsb3Blcl9zZWFy
>> "!B64TMP!" echo Y2gucHkiCkFDQ09VTlRfUEFTUz0xCmZvciBmIGluICRBTExfU0tJTExfRklMRVM7IGRvCiAgaWYg
>> "!B64TMP!" echo WyAtcyAiJFNLSUxMX0RJUi8kZiIgXTsgdGhlbiA6OyBlbHNlCiAgICBlY2hvICIgIFtGQUlMXSBh
>> "!B64TMP!" echo Y2NvdW50LW1vZGUgc2tpbGwgbWlzc2luZzogJGYiCiAgICBBQ0NPVU5UX1BBU1M9MDsgUEFTUz0w
>> "!B64TMP!" echo CiAgZmkKZG9uZQppZiBbICIkQUNDT1VOVF9QQVNTIiA9IDEgXTsgdGhlbgogIGVjaG8gIiAgW09L
>> "!B64TMP!" echo XSAgIGFsbCAyNSB0b29sIHNjcmlwdHMgKyBzaGFyZWQgbW9kdWxlcyBpbiB0aGUgYWNjb3VudC1t
>> "!B64TMP!" echo b2RlIHNraWxsIgpmaQoKIyAtLS0gYWNjb3VudC1tb2RlOiBmaXJlY3Jhd2xfYXBpLnB5IG11c3Qg
>> "!B64TMP!" echo cGljayB0aGUgLmVudiBjcmVkZW50aWFscyB1cCAtLS0tLS0tCiIkUFkiIC0gPDwnUFlFT0YzJwpp
>> "!B64TMP!" echo bXBvcnQgc3lzLCBvcwpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5leHBhbmR1c2VyKCJ+Ly5h
>> "!B64TMP!" echo Z2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cyIpKQpmb3IgdmFyIGluICgiTE9D
>> "!B64TMP!" echo QUxfU0VBUkNIX0RJUiIsICJGSVJFQ1JBV0xfQVBJX1VSTCIsICJGSVJFQ1JBV0xfQVBJX0tFWSIp
>> "!B64TMP!" echo OgogICAgb3MuZW52aXJvbi5wb3AodmFyLCBOb25lKQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBm
>> "!B64TMP!" echo YwppZiBmYy5iYXNlX3VybCgpID09ICJodHRwczovL2FwaS5maXJlY3Jhd2wuZGV2IjoKICAgIHBy
>> "!B64TMP!" echo aW50KCIgIFtPS10gICBmaXJlY3Jhd2xfYXBpLmJhc2VfdXJsKCkgcmVhZHMgRklSRUNSQVdMX0FQ
>> "!B64TMP!" echo SV9VUkwgZnJvbSB0aGUgaW5zdGFsbCAuZW52IikKZWxzZToKICAgIHByaW50KCIgIFtGQUlMXSBm
>> "!B64TMP!" echo aXJlY3Jhd2xfYXBpLmJhc2VfdXJsKCkgPSAlcyIgJSBmYy5iYXNlX3VybCgpKTsgc3lzLmV4aXQo
>> "!B64TMP!" echo MSkKaWYgbm90IGZjLmlzX2xvY2FsKCk6CiAgICBwcmludCgiICBbT0tdICAgZmlyZWNyYXdsX2Fw
>> "!B64TMP!" echo aS5pc19sb2NhbCgpIGlzIEZhbHNlIChyZW1vdGUgYWNjb3VudCBtb2RlKSIpCmVsc2U6CiAgICBw
>> "!B64TMP!" echo cmludCgiICBbRkFJTF0gZmlyZWNyYXdsX2FwaS5pc19sb2NhbCgpIHNob3VsZCBiZSBGYWxzZSBp
>> "!B64TMP!" echo biBhY2NvdW50IG1vZGUiKTsgc3lzLmV4aXQoMSkKaGRycyA9IGZjLmF1dGhfaGVhZGVycygpCmlm
>> "!B64TMP!" echo IGhkcnMuZ2V0KCJBdXRob3JpemF0aW9uIikgPT0gIkJlYXJlciBmYy1lMmUtdGVzdC1rZXktMTIz
>> "!B64TMP!" echo IjoKICAgIHByaW50KCIgIFtPS10gICBhdXRoX2hlYWRlcnMoKSBjYXJyaWVzIHRoZSBCZWFyZXIg
>> "!B64TMP!" echo a2V5IGZyb20gdGhlIGluc3RhbGwgLmVudiIpCmVsc2U6CiAgICBwcmludCgiICBbRkFJTF0gQXV0
>> "!B64TMP!" echo aG9yaXphdGlvbiBoZWFkZXIgd3Jvbmc6ICVyIiAlIGhkcnMuZ2V0KCJBdXRob3JpemF0aW9uIikp
>> "!B64TMP!" echo OyBzeXMuZXhpdCgxKQpQWUVPRjMKWyAkPyA9IDAgXSB8fCBQQVNTPTAKCiMgLS0tIGFjY291bnQt
>> "!B64TMP!" echo bW9kZTogZXZlcnkgdG9vbCBzY3JpcHQgcm91dGVzIHRvIHRoZSBjbG91ZCBBUEkgLS0tLS0tLS0t
>> "!B64TMP!" echo LS0tLS0tCiIkUFkiIC0gPDwnUFlFT0Y0JwppbXBvcnQgc3lzLCBvcwpzeXMucGF0aC5pbnNlcnQo
>> "!B64TMP!" echo MCwgb3MucGF0aC5leHBhbmR1c2VyKCJ+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gv
>> "!B64TMP!" echo c2NyaXB0cyIpKQpmb3IgdmFyIGluICgiTE9DQUxfU0VBUkNIX0RJUiIsICJGSVJFQ1JBV0xfQVBJ
>> "!B64TMP!" echo X1VSTCIsICJGSVJFQ1JBV0xfQVBJX0tFWSIpOgogICAgb3MuZW52aXJvbi5wb3AodmFyLCBOb25l
>> "!B64TMP!" echo KQpjaGVja3MgPSBbCiAgICAoIndlYl9tYXAiLCAgICAgICAgICAgICAgIi92MS9tYXAiKSwKICAg
>> "!B64TMP!" echo ICgid2ViX2NyYXdsIiwgICAgICAgICAgICAiL3YxL2NyYXdsIiksCiAgICAoIndlYl9jcmF3bF9z
>> "!B64TMP!" echo dGF0dXMiLCAgICAgIi92MS9jcmF3bCIpLAogICAgKCJ3ZWJfYWdlbnQiLCAgICAgICAgICAgICIv
>> "!B64TMP!" echo djEvYWdlbnQiKSwKICAgICgid2ViX2FnZW50X3N0YXR1cyIsICAgICAiL3YxL2FnZW50IiksCiAg
>> "!B64TMP!" echo ICAoIndlYl9pbnRlcmFjdCIsICAgICAgICAgIi92MS9pbnRlcmFjdCIpLAogICAgKCJ3ZWJfaW50
>> "!B64TMP!" echo ZXJhY3Rfc3RvcCIsICAgICIvdjEvaW50ZXJhY3QiKSwKICAgICgid2ViX3BhcnNlIiwgICAgICAg
>> "!B64TMP!" echo ICAgICAiL3YxL3BhcnNlIiksCiAgICAoIndlYl9tb25pdG9yX2NyZWF0ZSIsICAgIi92MS9tb25p
>> "!B64TMP!" echo dG9yIiksCiAgICAoIndlYl9tb25pdG9yX2xpc3QiLCAgICAgIi92MS9tb25pdG9yIiksCiAgICAo
>> "!B64TMP!" echo IndlYl9tb25pdG9yX2dldCIsICAgICAgIi92MS9tb25pdG9yIiksCiAgICAoIndlYl9tb25pdG9y
>> "!B64TMP!" echo X3VwZGF0ZSIsICAgIi92MS9tb25pdG9yIiksCiAgICAoIndlYl9tb25pdG9yX2RlbGV0ZSIsICAg
>> "!B64TMP!" echo Ii92MS9tb25pdG9yIiksCiAgICAoIndlYl9tb25pdG9yX3J1biIsICAgICAgIi92MS9tb25pdG9y
>> "!B64TMP!" echo IiksCiAgICAoIndlYl9tb25pdG9yX2NoZWNrcyIsICAgIi92MS9tb25pdG9yIiksCiAgICAoIndl
>> "!B64TMP!" echo Yl9tb25pdG9yX2NoZWNrIiwgICAgIi92MS9tb25pdG9yIiksCiAgICAoIndlYl9yZXNlYXJjaF9z
>> "!B64TMP!" echo ZWFyY2giLCAgIi92MS9yZXNlYXJjaC9zZWFyY2gvcGFwZXJzIiksCiAgICAoIndlYl9yZXNlYXJj
>> "!B64TMP!" echo aF9pbnNwZWN0IiwgIi92MS9yZXNlYXJjaC9wYXBlcnMiKSwKICAgICgid2ViX3Jlc2VhcmNoX3Jl
>> "!B64TMP!" echo bGF0ZWQiLCAiL3YxL3Jlc2VhcmNoL3JlbGF0ZWQiKSwKICAgICgid2ViX3Jlc2VhcmNoX3JlYWQi
>> "!B64TMP!" echo LCAgICAiL3YxL3Jlc2VhcmNoL3BhcGVycyIpLAogICAgKCJ3ZWJfZ2l0aHViX3NlYXJjaCIsICAg
>> "!B64TMP!" echo ICIvdjEvcmVzZWFyY2gvc2VhcmNoL2dpdGh1YiIpLAogICAgKCJ3ZWJfZGV2ZWxvcGVyX3NlYXJj
>> "!B64TMP!" echo aCIsICIvdjEvZGV2ZWxvcGVyL3NlYXJjaCIpLApdCmZvciBuYW1lLCBzdWZmaXggaW4gY2hlY2tz
>> "!B64TMP!" echo OgogICAgbW9kID0gX19pbXBvcnRfXyhuYW1lKQogICAgZW5kcG9pbnQgPSBtb2QuRU5EUE9JTlQK
>> "!B64TMP!" echo ICAgIGlmIGVuZHBvaW50LnN0YXJ0c3dpdGgoImh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYiKSBh
>> "!B64TMP!" echo bmQgZW5kcG9pbnQuZW5kc3dpdGgoc3VmZml4KToKICAgICAgICBwcmludCgiICBbT0tdICAgJXMu
>> "!B64TMP!" echo RU5EUE9JTlQgPSAlcyIgJSAobmFtZSwgZW5kcG9pbnQpKQogICAgZWxzZToKICAgICAgICBwcmlu
>> "!B64TMP!" echo dCgiICBbRkFJTF0gJXMuRU5EUE9JTlQgPSAlcyAoZXhwZWN0ZWQgY2xvdWQgQVBJICsgJXMpIiAl
>> "!B64TMP!" echo IChuYW1lLCBlbmRwb2ludCwgc3VmZml4KSkKICAgICAgICBzeXMuZXhpdCgxKQpwcmludCgiICBb
>> "!B64TMP!" echo T0tdICAgYWxsIDIyIEZpcmVjcmF3bCB0b29sIHNjcmlwdHMgcm91dGUgdG8gdGhlIGNsb3VkIEFQ
>> "!B64TMP!" echo SSIpClBZRU9GNApbICQ/ID0gMCBdIHx8IFBBU1M9MAoKIyAtLS0gZG9ja2VyIGF1dG8tc3RhcnQg
>> "!B64TMP!" echo dGVzdDogZW5naW5lIGRvd24gLT4gaW5zdGFsbGVyIHN0YXJ0cyBpdCAtLS0tLS0tLS0tCmVjaG8K
>> "!B64TMP!" echo ZWNobyAiPT09PT0gZG9ja2VyIGF1dG8tc3RhcnQgdGVzdDogaW5zdGFsbGVyIGJvb3RzIGEgZG93
>> "!B64TMP!" echo biBlbmdpbmUgPT09PT0iCgojIG1vY2sgZG9ja2VyICM0OiBlbmdpbmUgRE9XTiB1bnRpbCBhIG1v
>> "!B64TMP!" echo Y2sgJ3N5c3RlbWN0bCBzdGFydCcgZmxpcHMgaXQgdXAKbWtkaXIgLXAgIiRURVNUUk9PVC9iaW40
>> "!B64TMP!" echo IgpjYXQgPiAiJFRFU1RST09UL2JpbjQvZG9ja2VyIiA8PCdNT0NLNCcKIyEvdXNyL2Jpbi9lbnYg
>> "!B64TMP!" echo YmFzaApjYXNlICIkMSIgaW4KICBpbmZvKQogICAgWyAtZiAiJERPQ0tFUl9VUF9NQVJLRVIiIF0g
>> "!B64TMP!" echo JiYgZXhpdCAwCiAgICBleGl0IDEgOzsKICBjb21wb3NlKQogICAgY2FzZSAiJDIiIGluCiAgICAg
>> "!B64TMP!" echo IHZlcnNpb24pIGVjaG8gIkRvY2tlciBDb21wb3NlIHZlcnNpb24gdjIuMC4wLXRlc3QiOyBleGl0
>> "!B64TMP!" echo IDAgOzsKICAgICAgKikgZWNobyAiW21vY2tdIG9rIjsgZXhpdCAwIDs7CiAgICBlc2FjIDs7CiAg
>> "!B64TMP!" echo KikgZXhpdCAwIDs7CmVzYWMKTU9DSzQKY2F0ID4gIiRURVNUUk9PVC9iaW40L3N5c3RlbWN0bCIg
>> "!B64TMP!" echo PDwnTU9DSzRTJwojIS91c3IvYmluL2VudiBiYXNoCiMgbW9jayBzeXN0ZW1kIGNvbnRyb2w6ICdz
>> "!B64TMP!" echo dGFydCA8dW5pdD4nIGJyaW5ncyB0aGUgZW5naW5lIHVwClsgIiQxIiA9ICJzdGFydCIgXSAmJiA6
>> "!B64TMP!" echo ID4gIiRET0NLRVJfVVBfTUFSS0VSIgpleGl0IDAKTU9DSzRTCmNobW9kICt4ICIkVEVTVFJPT1Qv
>> "!B64TMP!" echo YmluNC9kb2NrZXIiICIkVEVTVFJPT1QvYmluNC9zeXN0ZW1jdGwiCgpUR1QyPSIkVEVTVFJPT1Qv
>> "!B64TMP!" echo dGFyZ2V0MiIKVVBNQVJLPSIkVEVTVFJPT1QvZG9ja2VyX3VwLm1hcmtlciIKcHJpbnRmICclc1xu
>> "!B64TMP!" echo JXNcbiVzXG4lc1xuJXNcbiVzXG4nICIkVEdUMiIgIiIgIiIgIm4iICJuIiAieSIgXAogIHwgZW52
>> "!B64TMP!" echo IERPQ0tFUl9VUF9NQVJLRVI9IiRVUE1BUksiIFBBVEg9IiRURVNUUk9PVC9iaW40OiRQQVRIIiBc
>> "!B64TMP!" echo CiAgICAiJFNSQ19ESVIvaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giID4gIiRURVNUUk9PVC9pbnN0
>> "!B64TMP!" echo RC5sb2ciIDI+JjEKRFJDPSQ/CmlmIFsgIiREUkMiID0gMCBdICYmIGdyZXAgLXEgInRyeWluZyB0
>> "!B64TMP!" echo byBzdGFydCBpdCIgIiRURVNUUk9PVC9pbnN0RC5sb2ciIFwKICAgJiYgZ3JlcCAtcSAiTGF1bmNo
>> "!B64TMP!" echo ZWQgRG9ja2VyIGluIHRoZSBiYWNrZ3JvdW5kIiAiJFRFU1RST09UL2luc3RELmxvZyIgXAogICAm
>> "!B64TMP!" echo JiBncmVwIC1xICJlbmdpbmUgaXMgb25saW5lIiAiJFRFU1RST09UL2luc3RELmxvZyIgXAogICAm
>> "!B64TMP!" echo JiBbIC1mICIkVVBNQVJLIiBdICYmIFsgLXMgIiRUR1QyL2RvY2tlci1jb21wb3NlLnltbCIgXTsg
>> "!B64TMP!" echo dGhlbgogIGVjaG8gIiAgW09LXSAgIGF1dG8tc3RhcnQ6IGluc3RhbGxlciBsYXVuY2hlZCB0aGUg
>> "!B64TMP!" echo ZW5naW5lLCB3YWl0ZWQsIGZpbmlzaGVkIgplbHNlCiAgZWNobyAiICBbRkFJTF0gZG9ja2VyIGF1
>> "!B64TMP!" echo dG8tc3RhcnQgaW5zdGFsbCI7IHRhaWwgLTIwICIkVEVTVFJPT1QvaW5zdEQubG9nIjsgUEFTUz0w
>> "!B64TMP!" echo CmZpCgojIG1vY2sgZG9ja2VyICM1OiBlbmdpbmUgZG93biBhbmQgTk9USElORyBjYW4gc3RhcnQg
>> "!B64TMP!" echo aXQgLT4gY2xlYW4gZmFpbHVyZQpta2RpciAtcCAiJFRFU1RST09UL2JpbjUiCmNhdCA+ICIkVEVT
>> "!B64TMP!" echo VFJPT1QvYmluNS9kb2NrZXIiIDw8J01PQ0s1JwojIS91c3IvYmluL2VudiBiYXNoCmNhc2UgIiQx
>> "!B64TMP!" echo IiBpbgogIGluZm8pIGV4aXQgMSA7OwogICopIGV4aXQgMCA7Owplc2FjCk1PQ0s1CmNobW9kICt4
>> "!B64TMP!" echo ICIkVEVTVFJPT1QvYmluNS9kb2NrZXIiCmZvciBtIGluIHN5c3RlbWN0bCBzZXJ2aWNlIHN1ZG87
>> "!B64TMP!" echo IGRvCiAgcHJpbnRmICcjIS91c3IvYmluL2VudiBiYXNoXG5leGl0IDFcbicgPiAiJFRFU1RST09U
>> "!B64TMP!" echo L2JpbjUvJG0iCiAgY2htb2QgK3ggIiRURVNUUk9PVC9iaW41LyRtIgpkb25lCnByaW50ZiAnJXNc
>> "!B64TMP!" echo biVzXG4lc1xuJXNcbiVzXG4lc1xuJyAiJFRFU1RST09UL3RhcmdldDUiICIiICIiICJuIiAibiIg
>> "!B64TMP!" echo InkiIFwKICB8IGVudiBQQVRIPSIkVEVTVFJPT1QvYmluNTokUEFUSCIgIiRTUkNfRElSL2luc3Rh
>> "!B64TMP!" echo bGwtbG9jYWwtc2VhcmNoLnNoIiBcCiAgICA+ICIkVEVTVFJPT1QvaW5zdEQyLmxvZyIgMj4mMQpE
>> "!B64TMP!" echo MlJDPSQ/CmlmIFsgIiREMlJDIiAhPSAwIF0gXAogICAmJiBncmVwIC1xICJDb3VsZCBub3Qgc3Rh
>> "!B64TMP!" echo cnQgdGhlIERvY2tlciBlbmdpbmUiICIkVEVTVFJPT1QvaW5zdEQyLmxvZyI7IHRoZW4KICBlY2hv
>> "!B64TMP!" echo ICIgIFtPS10gICBhdXRvLXN0YXJ0IGZhaWx1cmU6IGNsZWFuIGVycm9yICsgZXhpdCAxIHdoZW4g
>> "!B64TMP!" echo bm90aGluZyBjYW4gc3RhcnQgaXQiCmVsc2UKICBlY2hvICIgIFtGQUlMXSBleHBlY3RlZCBjbGVh
>> "!B64TMP!" echo biBmYWlsdXJlIHdoZW4gdGhlIGVuZ2luZSBjYW5ub3QgYmUgc3RhcnRlZCIKICB0YWlsIC0yMCAi
>> "!B64TMP!" echo JFRFU1RST09UL2luc3REMi5sb2ciOyBQQVNTPTAKZmkKCiMgbW9jayBkb2NrZXIgIzY6IHN5c3Rl
>> "!B64TMP!" echo bWN0bCAnc3RhcnRzJyB0aGUgZW5naW5lIGJ1dCBkb2NrZXIgaW5mbyBuZXZlciB3b3Jrcwpta2Rp
>> "!B64TMP!" echo ciAtcCAiJFRFU1RST09UL2JpbjYiCmNwICIkVEVTVFJPT1QvYmluNS9kb2NrZXIiICIkVEVTVFJP
>> "!B64TMP!" echo T1QvYmluNi9kb2NrZXIiCnByaW50ZiAnIyEvdXNyL2Jpbi9lbnYgYmFzaFxuZXhpdCAwXG4nID4g
>> "!B64TMP!" echo IiRURVNUUk9PVC9iaW42L3N5c3RlbWN0bCIKY2htb2QgK3ggIiRURVNUUk9PVC9iaW42L2RvY2tl
>> "!B64TMP!" echo ciIgIiRURVNUUk9PVC9iaW42L3N5c3RlbWN0bCIKcHJpbnRmICclc1xuJXNcbiVzXG4lc1xuJXNc
>> "!B64TMP!" echo biVzXG4nICIkVEVTVFJPT1QvdGFyZ2V0NiIgIiIgIiIgIm4iICJuIiAieSIgXAogIHwgZW52IExP
>> "!B64TMP!" echo Q0FMX1NFQVJDSF9ET0NLRVJfVElNRU9VVD0yIFBBVEg9IiRURVNUUk9PVC9iaW42OiRQQVRIIiBc
>> "!B64TMP!" echo CiAgICAiJFNSQ19ESVIvaW5zdGFsbC1sb2NhbC1zZWFyY2guc2giID4gIiRURVNUUk9PVC9pbnN0
>> "!B64TMP!" echo RDMubG9nIiAyPiYxCkQzUkM9JD8KaWYgWyAiJEQzUkMiICE9IDAgXSAmJiBncmVwIC1xICJkaWQg
>> "!B64TMP!" echo bm90IGNvbWUgb25saW5lIiAiJFRFU1RST09UL2luc3REMy5sb2ciOyB0aGVuCiAgZWNobyAiICBb
>> "!B64TMP!" echo T0tdICAgZW5naW5lLXdhaXQgdGltZW91dDogY2xlYW4gZXJyb3IgYWZ0ZXIgTE9DQUxfU0VBUkNI
>> "!B64TMP!" echo X0RPQ0tFUl9USU1FT1VUIgplbHNlCiAgZWNobyAiICBbRkFJTF0gZXhwZWN0ZWQgdGltZW91dCBm
>> "!B64TMP!" echo YWlsdXJlIHdoZW4gdGhlIGVuZ2luZSBuZXZlciBjb21lcyBvbmxpbmUiCiAgdGFpbCAtMjAgIiRU
>> "!B64TMP!" echo RVNUUk9PVC9pbnN0RDMubG9nIjsgUEFTUz0wCmZpCgojIC0tLSBub3cgcnVuIHRoZSB1bmluc3Rh
>> "!B64TMP!" echo bGxlciAoa2VlcCBmb2xkZXIpIGFuZCB2ZXJpZnkgdGhlIHNraWxsIGlzIHJlbW92ZWQgLS0KZWNo
>> "!B64TMP!" echo bwplY2hvICI9PT09PSBydW5uaW5nIHVuaW5zdGFsbGVyIChhbnN3ZXJpbmcgeSwgdGhlbiBuIGZv
>> "!B64TMP!" echo ciBmb2xkZXIgZGVsZXRlKSA9PT09PSIKcHJpbnRmICd5XG5uXG4nIHwgIiRUR1RfRElSL3VuaW5z
>> "!B64TMP!" echo dGFsbC5zaCIgPiAiJFRFU1RST09UL3VuaW5zdGFsbC5sb2ciIDI+JjEKVVJDPSQ/CmVjaG8gIlVu
>> "!B64TMP!" echo aW5zdGFsbGVyIGV4aXQgY29kZTogJFVSQyIKdGFpbCAtMTIgIiRURVNUUk9PVC91bmluc3RhbGwu
>> "!B64TMP!" echo bG9nIgplY2hvICItLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSIKaWYgWyAhIC1kICIk
>> "!B64TMP!" echo U0tJTExfRElSIiBdOyB0aGVuCiAgZWNobyAiW09LXSB1bmluc3RhbGxlciByZW1vdmVkIHRoZSBz
>> "!B64TMP!" echo a2lsbCBkaXIiCmVsc2UKICBlY2hvICJbRkFJTF0gc2tpbGwgZGlyIHN0aWxsIGV4aXN0cyBhZnRl
>> "!B64TMP!" echo ciB1bmluc3RhbGwiCiAgUEFTUz0wCmZpCmlmIFsgLWYgIiRUR1RfRElSLy5lbnYiIF0gJiYgWyAt
>> "!B64TMP!" echo ZCAiJFRHVF9ESVIvbG9jYWwtd2ViLXNlYXJjaCIgXTsgdGhlbgogIGVjaG8gIltPS10gdW5pbnN0
>> "!B64TMP!" echo YWxsZXIga2VwdCB0aGUgaW5zdGFsbCBmb2xkZXIgKGFzIGFuc3dlcmVkKSIKZWxzZQogIGVjaG8g
>> "!B64TMP!" echo IltGQUlMXSB1bmluc3RhbGxlciBkZWxldGVkIHRoZSBpbnN0YWxsIGZvbGRlciBkZXNwaXRlICdu
>> "!B64TMP!" echo JyIKICBQQVNTPTAKZmkKCmVjaG8KaWYgWyAiJFBBU1MiID0gMSBdOyB0aGVuCiAgZWNobyAiPT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09ICBBTEwgVEVTVFMgUEFTU0VEICA9PT09PT09PT09PT09PT09
>> "!B64TMP!" echo PT09PT09PT0iCiAgZXhpdCAwCmZpCmVjaG8gIj09PT09PT09PT09PT09PT09PT09PT09PSAgVEVT
>> "!B64TMP!" echo VFMgRkFJTEVEICA9PT09PT09PT09PT09PT09PT09PT09PT09PT0iCmV4aXQgMQo=
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
>> "!B64TMP!" echo ICAgbG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl95b3V0dWJlX3RyYW5zY3JpcHQucHkgXAog
>> "!B64TMP!" echo ICAgICAgICBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQgaW5zdGFsbC1sb2NhbC1zZWFyY2guc2g7
>> "!B64TMP!" echo IGRvCiAgaWYgWyAtcyAiJFRHVC8kZiIgXTsgdGhlbgogICAgZWNobyAiICBbT0tdICRmIgogIGVs
>> "!B64TMP!" echo c2UKICAgIGVjaG8gIiAgW0ZBSUxdICRmIChtaXNzaW5nL2VtcHR5KSI7IFBBU1M9MAogIGZpCmRv
>> "!B64TMP!" echo bmUKCmlmIGdyZXAgLXEgJ19fU0VBUlhOR19TRUNSRVRfUExBQ0VIT0xERVJfXycgIiRUR1QvY29u
>> "!B64TMP!" echo ZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sIjsgdGhlbgogIGVjaG8gIltGQUlMXSBzZXR0aW5ncy55
>> "!B64TMP!" echo bWwgc3RpbGwgaGFzIHBsYWNlaG9sZGVyIjsgUEFTUz0wCmVsc2UKICBlY2hvICJbT0tdIHNldHRp
>> "!B64TMP!" echo bmdzLnltbCBzZWNyZXQgaW5qZWN0ZWQiCmZpCgojIGNvcmUtb25seSBkZWZhdWx0OiBubyBhY2Nv
>> "!B64TMP!" echo dW50LWdhdGVkIHRvb2xzLCBjb3JlIFNLSUxMLm1kLCBubyBsZWFrZWQgdmFyaWFudAppZiBbIC1l
>> "!B64TMP!" echo ICIkVEdUL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfYWdlbnQucHkiIF0gXAogICB8fCBb
>> "!B64TMP!" echo IC1lICIkVEdUL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbW9uaXRvcl9jcmVhdGUucHki
>> "!B64TMP!" echo IF0gXAogICB8fCBbIC1lICIkVEdUL2xvY2FsLXdlYi1zZWFyY2gvU0tJTEwtY29yZS5tZCIgXTsg
>> "!B64TMP!" echo dGhlbgogIGVjaG8gIltGQUlMXSBhY2NvdW50LWdhdGVkIHRvb2xzIChvciBTS0lMTC1jb3JlLm1k
>> "!B64TMP!" echo KSBpbnN0YWxsZWQgaW4gY29yZSBtb2RlIjsgUEFTUz0wCmVsc2UKICBlY2hvICJbT0tdIGNvcmUt
>> "!B64TMP!" echo b25seSBza2lsbDogYWNjb3VudC1nYXRlZCB0b29scyBza2lwcGVkLCBubyBTS0lMTC1jb3JlLm1k
>> "!B64TMP!" echo IgpmaQppZiBncmVwIC1xICI2IHRvb2xzOiBzZWFyY2gsIHNjcmFwZSwgbWFwLCBjcmF3bCwgY3Jh
>> "!B64TMP!" echo d2wgc3RhdHVzLCBZb3VUdWJlIiAiJFRHVC9sb2NhbC13ZWItc2VhcmNoL1NLSUxMLm1kIjsgdGhl
>> "!B64TMP!" echo bgogIGVjaG8gIltPS10gU0tJTEwubWQgaXMgdGhlIGNvcmUtb25seSB2YXJpYW50IgplbHNlCiAg
>> "!B64TMP!" echo ZWNobyAiW0ZBSUxdIFNLSUxMLm1kIGlzIG5vdCB0aGUgY29yZS1vbmx5IHZhcmlhbnQiOyBQQVNT
>> "!B64TMP!" echo PTAKZmkKCmlmIFsgIiQoY2F0ICIkU0tJTExfRElSL2luc3RhbGwtZGlyLnR4dCIgMj4vZGV2L251
>> "!B64TMP!" echo bGwpIiA9ICIkVEdUIiBdOyB0aGVuCiAgZWNobyAiW09LXSBza2lsbCBpbnN0YWxsZWQgd2l0aCBj
>> "!B64TMP!" echo b3JyZWN0IGluc3RhbGwtZGlyLnR4dCBoaW50IgplbHNlCiAgZWNobyAiW0ZBSUxdIHNraWxsIGlu
>> "!B64TMP!" echo c3RhbGwtZGlyLnR4dCB3cm9uZzogJChjYXQgIiRTS0lMTF9ESVIvaW5zdGFsbC1kaXIudHh0IiAy
>> "!B64TMP!" echo Pi9kZXYvbnVsbCkiCiAgUEFTUz0wCmZpCgpjbXAgLXMgIiRUR1QvaW5zdGFsbC1sb2NhbC1zZWFy
>> "!B64TMP!" echo Y2guYmF0IiAiJFJPT1QvbG9jYWwtc2VhcmNoL2luc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCIgXAog
>> "!B64TMP!" echo ICYmIGVjaG8gIltPS10gLmJhdCByZXByb2R1Y2VkIGJ5dGUtaWRlbnRpY2FsIiBcCiAgfHwgeyBl
>> "!B64TMP!" echo Y2hvICJbRkFJTF0gLmJhdCBkaWZmZXJzIjsgUEFTUz0wOyB9CgplY2hvCmlmIFsgIiRQQVNTIiA9
>> "!B64TMP!" echo IDEgXSAmJiBbICIkUkMiID0gMCBdOyB0aGVuCiAgZWNobyAiPT09PT09PT0gRlVMTC1aSVAgRVhU
>> "!B64TMP!" echo UkFDVElPTiBURVNUOiBQQVNTRUQgPT09PT09PT0iCiAgZXhpdCAwCmZpCmVjaG8gIj09PT09PT09
>> "!B64TMP!" echo IEZVTEwtWklQIEVYVFJBQ1RJT04gVEVTVDogRkFJTEVEID09PT09PT09IgpleGl0IDEK
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
>> "!B64TMP!" echo Yl9zZWFyY2gucHkgbG9jYWwtd2ViLXNlYXJjaC9zY3JpcHRzL3dlYl9zY3JhcGUucHkgXAogICAg
>> "!B64TMP!" echo ICAgICBsb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weTsg
>> "!B64TMP!" echo ZG8KICBjaGVja19maWxlICJsb2NhbC1zZWFyY2gvJGYiCmRvbmUKIyBOT1RFOiBsb2NhbC1zZWFy
>> "!B64TMP!" echo Y2gvaW5zdGFsbC1sb2NhbC1zZWFyY2guKiBhcmUgaW50ZW50aW9uYWxseSBOT1QgdW5wYWNrZWQg
>> "!B64TMP!" echo YnkKIyB0aGUgcGFja2VyICh0aGV5IGFyZSBnZW5lcmF0ZWQgYXJ0aWZhY3RzKSAtIHRoZXkgYXJl
>> "!B64TMP!" echo IHZlcmlmaWVkIGluIHN0ZXAgNS4KCmZvciBmIGluIGdlbl9pbnN0YWxsZXJzLnB5IGdlbl9yaWcu
>> "!B64TMP!" echo cHkgdGVzdF9iNjQucHkgdGVzdF9oZXJlZG9jcy5weSB0ZXN0X3JpZy5weSBcCiAgICAgICAgIGUy
>> "!B64TMP!" echo ZV90ZXN0LnNoIHppcF90ZXN0LnNoIGJ1aWxkLnNoIGJ1aWxkLmJhdCBCVUlMRC5tZCBcCiAgICAg
>> "!B64TMP!" echo ICAgIGxvY2FsLXNlYXJjaC1yaWcuYmF0IGxvY2FsLXNlYXJjaC1yaWcuc2g7IGRvCiAgY2hlY2tf
>> "!B64TMP!" echo ZmlsZSAiJGYiCmRvbmUKCiMgLmJhdCBmaWxlcyB1bnBhY2tlZCBieSB0aGUgLnNoIHBhY2tlciBt
>> "!B64TMP!" echo dXN0IGhhdmUgQ1JMRiBlbmRpbmdzCmZvciBmIGluIGxvY2FsLXNlYXJjaC9SdW4uYmF0IGxvY2Fs
>> "!B64TMP!" echo LXNlYXJjaC9VcGRhdGUuYmF0IGxvY2FsLXNlYXJjaC1yaWcuYmF0IGJ1aWxkLmJhdDsgZG8KICBp
>> "!B64TMP!" echo ZiBncmVwIC1xICQnXHInICIkVEVTVFJPT1QvcmlnLyRmIiAyPi9kZXYvbnVsbDsgdGhlbgogICAg
>> "!B64TMP!" echo ZWNobyAiICBbT0tdICAgJGYgaGFzIENSTEYiCiAgZWxzZQogICAgZWNobyAiICBbRkFJTF0gJGYg
>> "!B64TMP!" echo bGFja3MgQ1JMRiI7IFBBU1M9MAogIGZpCmRvbmUKZWNobwoKZWNobyAiPT09IDQuIFNFTEYtSE9T
>> "!B64TMP!" echo VElORzogcmVnZW5lcmF0ZSBwYWNrZXJzIGluc2lkZSB1bnBhY2tlZCByaWcgPT09IgppZiAoY2Qg
>> "!B64TMP!" echo IiRURVNUUk9PVC9yaWciICYmIHB5dGhvbjMgZ2VuX3JpZy5weSk7IHRoZW4KICBpZiBjbXAgLXMg
>> "!B64TMP!" echo IiRST09UL2xvY2FsLXNlYXJjaC1yaWcuc2giICIkVEVTVFJPT1QvcmlnL2xvY2FsLXNlYXJjaC1y
>> "!B64TMP!" echo aWcuc2giOyB0aGVuCiAgICBlY2hvICIgIFtPS10gbG9jYWwtc2VhcmNoLXJpZy5zaCByZWdlbmVy
>> "!B64TMP!" echo YXRlZCBCWVRFLUlERU5USUNBTCIKICBlbHNlCiAgICBlY2hvICIgIFtGQUlMXSBsb2NhbC1zZWFy
>> "!B64TMP!" echo Y2gtcmlnLnNoIGRpZmZlcnMgYWZ0ZXIgcmVnZW5lcmF0aW9uIjsgUEFTUz0wCiAgZmkKICBpZiBj
>> "!B64TMP!" echo bXAgLXMgIiRST09UL2xvY2FsLXNlYXJjaC1yaWcuYmF0IiAiJFRFU1RST09UL3JpZy9sb2NhbC1z
>> "!B64TMP!" echo ZWFyY2gtcmlnLmJhdCI7IHRoZW4KICAgIGVjaG8gIiAgW09LXSBsb2NhbC1zZWFyY2gtcmlnLmJh
>> "!B64TMP!" echo dCByZWdlbmVyYXRlZCBCWVRFLUlERU5USUNBTCIKICBlbHNlCiAgICBlY2hvICIgIFtGQUlMXSBs
>> "!B64TMP!" echo b2NhbC1zZWFyY2gtcmlnLmJhdCBkaWZmZXJzIGFmdGVyIHJlZ2VuZXJhdGlvbiI7IFBBU1M9MAog
>> "!B64TMP!" echo IGZpCmVsc2UKICBlY2hvICIgIFtGQUlMXSBnZW5fcmlnLnB5IGZhaWxlZCBpbiB1bnBhY2tlZCBy
>> "!B64TMP!" echo aWciOyBQQVNTPTAKZmkKZWNobwoKZWNobyAiPT09IDUuIHJlZ2VuZXJhdGUgaW5zdGFsbGVycyBp
>> "!B64TMP!" echo bnNpZGUgdW5wYWNrZWQgcmlnID09PSIKaWYgKGNkICIkVEVTVFJPT1QvcmlnIiAmJiBweXRob24z
>> "!B64TMP!" echo IGdlbl9pbnN0YWxsZXJzLnB5KTsgdGhlbgogIGlmIGNtcCAtcyAiJFJPT1QvbG9jYWwtc2VhcmNo
>> "!B64TMP!" echo L2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoIiAiJFRFU1RST09UL3JpZy9sb2NhbC1zZWFyY2gvaW5z
>> "!B64TMP!" echo dGFsbC1sb2NhbC1zZWFyY2guc2giOyB0aGVuCiAgICBlY2hvICIgIFtPS10gaW5zdGFsbC1sb2Nh
>> "!B64TMP!" echo bC1zZWFyY2guc2ggcmVnZW5lcmF0ZWQgQllURS1JREVOVElDQUwiCiAgZWxzZQogICAgZWNobyAi
>> "!B64TMP!" echo ICBbRkFJTF0gaW5zdGFsbC1sb2NhbC1zZWFyY2guc2ggZGlmZmVycyI7IFBBU1M9MAogIGZpCiAg
>> "!B64TMP!" echo aWYgY21wIC1zICIkUk9PVC9sb2NhbC1zZWFyY2gvaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IiAi
>> "!B64TMP!" echo JFRFU1RST09UL3JpZy9sb2NhbC1zZWFyY2gvaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IjsgdGhl
>> "!B64TMP!" echo bgogICAgZWNobyAiICBbT0tdIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCByZWdlbmVyYXRlZCBC
>> "!B64TMP!" echo WVRFLUlERU5USUNBTCIKICBlbHNlCiAgICBlY2hvICIgIFtGQUlMXSBpbnN0YWxsLWxvY2FsLXNl
>> "!B64TMP!" echo YXJjaC5iYXQgZGlmZmVycyI7IFBBU1M9MAogIGZpCmVsc2UKICBlY2hvICIgIFtGQUlMXSBnZW5f
>> "!B64TMP!" echo aW5zdGFsbGVycy5weSBmYWlsZWQgaW4gdW5wYWNrZWQgcmlnIjsgUEFTUz0wCmZpCmVjaG8KCmVj
>> "!B64TMP!" echo aG8gIj09PSA2LiB2ZXJpZnkgdGVzdCBzdWl0ZSBwYXNzZXMgaW5zaWRlIHRoZSB1bnBhY2tlZCBy
>> "!B64TMP!" echo aWcgPT09IgppZiAoY2QgIiRURVNUUk9PVC9yaWciICYmIHB5dGhvbjMgdGVzdF9yaWcucHkgPiAv
>> "!B64TMP!" echo ZGV2L251bGwgMj4mMSk7IHRoZW4KICBlY2hvICIgIFtPS10gdGVzdF9yaWcucHkgcGFzc2VzIGlu
>> "!B64TMP!" echo IHVucGFja2VkIHJpZyIKZWxzZQogIGVjaG8gIiAgW0ZBSUxdIHRlc3RfcmlnLnB5IGZhaWxzIGlu
>> "!B64TMP!" echo IHVucGFja2VkIHJpZyI7IFBBU1M9MApmaQoKZWNobwppZiBbICIkUEFTUyIgPSAxIF07IHRoZW4K
>> "!B64TMP!" echo ICBlY2hvICI9PT09PT09PT09PT09PT09PSAgU0VMRi1IT1NUSU5HIFRFU1Q6IFBBU1NFRCAgPT09
>> "!B64TMP!" echo PT09PT09PT09PT09PT0iCiAgZXhpdCAwCmZpCmVjaG8gIj09PT09PT09PT09PT09PT09ICBTRUxG
>> "!B64TMP!" echo LUhPU1RJTkcgVEVTVDogRkFJTEVEICA9PT09PT09PT09PT09PT09PSIKZXhpdCAxCg==
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
echo   Done - 57 files + this packer.

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
