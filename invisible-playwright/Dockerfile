# =============================================================================
#  Invisible Playwright engine for Local Search
# =============================================================================
#  Built locally by `docker compose up` (there is no published image) when the
#  installer's Step 4 answer is "Invisible Playwright" (COMPOSE_PROFILES=invisible).
#
#  What it runs: server.py, a small HTTP service with the same two routes as
#  Firecrawl's playwright-service (POST /scrape, GET /health), driving
#  invisible-playwright - a patched Firefox - https://github.com/oss-invisible/playwright
#
#  The base image and the uv/venv recipe are the ones from that project's own
#  "use in Docker" guide: the base supplies Firefox's system libraries (and
#  Xvfb, which the package uses to run Firefox headed on a hidden screen); uv
#  supplies the Python >= 3.11 the package needs.
#
#  Build time needs: mcr.microsoft.com, ghcr.io, PyPI, and GitHub (uv's Python
#  download and the ~260 MB engine). If GitHub rate-limits the engine download,
#  put a token in .env as INVISIBLE_GITHUB_TOKEN (see .env.example); compose
#  passes it as the STEALTHFOX_GITHUB_TOKEN build argument below. (Build
#  arguments are visible in `docker history` of this local image - use a token
#  with no scopes.)
# =============================================================================
FROM mcr.microsoft.com/playwright/python:v1.47.0-jammy

COPY --from=ghcr.io/astral-sh/uv:0.12.10 /uv /uvx /bin/

ARG STEALTHFOX_GITHUB_TOKEN=""

ENV INVISIBLE_PLAYWRIGHT_CACHE_DIR=/opt/invisible-playwright-cache \
    VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    MALLOC_ARENA_MAX=2 \
    PYTHONUNBUFFERED=1

# Xvfb is already part of the base image; this makes sure of it (no-op if so).
RUN apt-get update \
 && apt-get install -y --no-install-recommends xvfb ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN uv venv --python ">=3.11" /opt/venv \
 && uv pip install --no-cache invisible-playwright aiohttp

# Download + verify the patched Firefox engine once, at build time. The ARG is
# not turned into an ENV, so the token is not part of the running container.
RUN python -m invisible_playwright fetch

# Pre-load the GeoIP database the automatic timezone uses, so the first start
# does not depend on reaching GitHub. Best effort: the service falls back to a
# fixed timezone if it is missing.
RUN python -c "from invisible_core.download import ensure_geoip_mmdb; ensure_geoip_mmdb()" \
 || echo "GeoIP pre-load skipped (the service will fetch it on first start)"

WORKDIR /app
COPY server.py /app/server.py

ENV PORT=3000
EXPOSE 3000

CMD ["python", "/app/server.py"]
