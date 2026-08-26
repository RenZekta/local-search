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
