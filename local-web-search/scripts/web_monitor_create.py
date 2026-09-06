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
