#!/usr/bin/env python3
"""Get the status, progress, and available results of an existing Firecrawl
crawl (the firecrawl_check_crawl_status MCP tool).

Usage:
    python web_crawl_status.py <id> [--max-pages N] [--max-chars N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints `Crawl <id>: <status> (completed/total pages)`; when the crawl has
finished, the collected pages follow as `N. <url>` + markdown truncated at
--max-chars chars (default 2000; up to --max-pages pages, default 25).
`--json` prints the raw API response instead. The status query itself only
fails (exit 1) when the API cannot be reached; a `failed` crawl still exits 0.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal
import web_crawl  # sibling: shared crawl output formatting

ENDPOINT = fc.url("/v1/crawl")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_crawl_status.py <id> [--max-pages N] [--max-chars N] "
              "[--json]", file=sys.stderr)
        return 2
    crawl_id = args[0]
    max_pages, max_chars, as_json = 25, 2000, False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--max-pages" and i + 1 < len(args):
            i += 1
            try:
                max_pages = int(args[i])
            except ValueError:
                print(f"invalid --max-pages: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--max-chars" and i + 1 < len(args):
            i += 1
            try:
                max_chars = int(args[i])
            except ValueError:
                print(f"invalid --max-chars: {args[i]}", file=sys.stderr)
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

    try:
        data = fc.call("/v1/crawl/" + str(crawl_id), method="GET")
    except fc.FcError as e:
        print(f"CRAWL STATUS FAILED for {crawl_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    print(f"Crawl {crawl_id}: {web_crawl.crawl_summary(data)}")
    web_crawl.print_pages(data, max_pages, max_chars)
    return 0


if __name__ == "__main__":
    sys.exit(main())
