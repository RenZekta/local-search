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
