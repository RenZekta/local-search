#!/usr/bin/env python3
"""Run a site crawl: start a multi-page Firecrawl crawl at a URL, poll it to
a terminal state, and report the final status and collected data (the
firecrawl_crawl MCP tool).

Usage:
    python web_crawl.py <url> [--prompt text] [--timeout S] [--poll-interval S]
                        [--max-pages N] [--max-chars N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Polls the crawl every --poll-interval seconds (default 2) until it reaches a
terminal state (completed / failed / cancelled) or --timeout seconds elapse
(default 300). Progress is printed to stderr. When the crawl completes, each
collected page prints as `N. <url>` followed by its markdown truncated at
--max-chars chars (default 2000; up to --max-pages pages, default 25).
`--json` prints the final status response instead.

If the crawl has not finished within --timeout, the crawl ID and current
progress are printed — keep polling with web_crawl_status.py <id>.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/crawl")

# Crawl-job states that mean "no more polling".
TERMINAL = ("completed", "failed", "cancelled", "stopped")


def crawl_summary(data):
    """One-line status summary from a crawl-status payload."""
    status = data.get("status") or "unknown"
    completed = data.get("completed")
    total = data.get("total")
    if completed is not None and total is not None:
        return f"{status} ({completed}/{total} pages)"
    return str(status)


def print_pages(data, max_pages, max_chars):
    """Print the collected pages: `N. <url>` + truncated markdown."""
    pages = data.get("data")
    if not isinstance(pages, list) or not pages:
        return
    shown = pages[:max_pages]
    for n, page in enumerate(shown, 1):
        if not isinstance(page, dict):
            continue
        print(f"{n}. {page.get('url') or page.get('sourceURL') or '(no url)'}")
        markdown = page.get("markdown") or ""
        if markdown:
            if len(markdown) > max_chars:
                markdown = markdown[:max_chars] \
                    + f"\n   [... truncated at {max_chars} chars ...]"
            for line in markdown.splitlines() or [""]:
                print(f"   {line}")
    if len(pages) > max_pages:
        print(f"[... {len(pages) - max_pages} more pages; raise --max-pages "
              f"or use --json ...]", file=sys.stderr)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_crawl.py <url> [--prompt text] [--timeout S] "
              "[--poll-interval S] [--max-pages N] [--max-chars N] [--json]",
              file=sys.stderr)
        return 2
    url = args[0]
    prompt = None
    timeout, poll_every = 300, 2
    max_pages, max_chars, as_json = 25, 2000, False
    i = 1

    def num(name):
        # `i` already points at the option's value (the branch incremented it).
        try:
            return int(args[i])
        except (ValueError, IndexError):
            print(f"invalid {name}: {args[i] if i < len(args) else ''}",
                  file=sys.stderr)
            sys.exit(2)

    while i < len(args):
        a = args[i]
        if a == "--prompt" and i + 1 < len(args):
            i += 1
            prompt = args[i]
        elif a == "--timeout" and i + 1 < len(args):
            i += 1
            timeout = num("--timeout")
        elif a == "--poll-interval" and i + 1 < len(args):
            i += 1
            poll_every = num("--poll-interval")
        elif a == "--max-pages" and i + 1 < len(args):
            i += 1
            max_pages = num("--max-pages")
        elif a == "--max-chars" and i + 1 < len(args):
            i += 1
            max_chars = num("--max-chars")
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            print(f"unexpected argument: {a}", file=sys.stderr)
            return 2
        i += 1

    body = {"url": url}
    if prompt:
        body["prompt"] = prompt

    # ---- start the crawl ------------------------------------------------
    try:
        started = fc.call("/v1/crawl", method="POST", body=body)
    except fc.FcError as e:
        print(f"CRAWL FAILED for {url}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1
    crawl_id = started.get("id") or (started.get("data") or {}).get("id")
    if not crawl_id:
        print("CRAWL FAILED for {}: the API did not return a crawl id. "
              "Response:".format(url), file=sys.stderr)
        print(json.dumps(started)[:800], file=sys.stderr)
        return 1
    print(f"Crawl started: {crawl_id}", file=sys.stderr)

    # ---- poll to a terminal state ---------------------------------------
    deadline = time.time() + timeout
    while True:
        try:
            data = fc.call("/v1/crawl/" + str(crawl_id), method="GET")
        except fc.FcError as e:
            print(f"CRAWL FAILED for {url}: status check failed: {e}",
                  file=sys.stderr)
            if e.hint:
                print(e.hint, file=sys.stderr)
            return 1
        status = str(data.get("status") or "unknown")
        if status in TERMINAL or (status not in
                                  ("active", "scraping", "queued", "processing",
                                   "waiting", "running") and data.get("data")):
            break
        if time.time() >= deadline:
            print(f"Crawl {crawl_id} still {crawl_summary(data)} after "
                  f"{timeout}s — keeping polling with:", file=sys.stderr)
            print(f"    python web_crawl_status.py {crawl_id}", file=sys.stderr)
            if as_json:
                print(json.dumps(data))
            else:
                print(f"Crawl {crawl_id}: {crawl_summary(data)} (timed out)")
            return 1
        print(f"  crawl {crawl_id}: {crawl_summary(data)}", file=sys.stderr)
        time.sleep(max(poll_every, 1))

    if as_json:
        print(json.dumps(data))
        return 0 if status == "completed" else 1

    if status != "completed":
        print(f"CRAWL FAILED for {url}: crawl {crawl_id} ended as "
              f"\"{status}\".", file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1

    credits = data.get("creditsUsed")
    suffix = f", {credits} credits used" if credits is not None else ""
    print(f"Crawl {crawl_id}: {crawl_summary(data)}{suffix}")
    print_pages(data, max_pages, max_chars)
    return 0


if __name__ == "__main__":
    sys.exit(main())
