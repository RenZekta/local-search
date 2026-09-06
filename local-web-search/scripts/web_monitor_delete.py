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
