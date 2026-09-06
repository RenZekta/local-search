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
