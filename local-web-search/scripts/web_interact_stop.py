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
