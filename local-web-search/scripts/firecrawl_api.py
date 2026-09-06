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
