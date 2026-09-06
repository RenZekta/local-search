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
