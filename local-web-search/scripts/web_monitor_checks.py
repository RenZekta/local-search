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
