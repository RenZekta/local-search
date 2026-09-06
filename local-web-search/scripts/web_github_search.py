#!/usr/bin/env python3
"""Search indexed public GitHub issue, pull-request, and README content via
the Firecrawl research index (the firecrawl_research_search_github MCP
tool).

Usage:
    python web_github_search.py "<query>" [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the ranked matches exactly like the MCP tool does — for each hit:

    [repo#123] (pull_request, 5 segments)
    https://github.com/...
    matched content (up to 1200 chars)

`--json` prints the raw API response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/research/search/github")

MAX_CONTENT_CHARS = 1200


def fmt_github(results):
    """Format ranked GitHub matches (mirrors the MCP tool's formatter)."""
    if not results:
        return "(no results)"
    blocks = []
    for r in results:
        if not isinstance(r, dict):
            blocks.append(str(r))
            continue
        lines = []
        repo = r.get("repo") or "?"
        number = r.get("number")
        if number is None and r.get("pageType") is None:
            lines.append(f"[{repo}] README")
        else:
            ref = f"#{number}" if number is not None else ""
            meta_parts = [str(r.get("pageType") or "")]
            if r.get("segmentCount"):
                meta_parts.append(f"{r['segmentCount']} segments")
            meta = ", ".join(p for p in meta_parts if p)
            lines.append(f"[{repo}{ref}]" + (f" ({meta})" if meta else ""))
        url = r.get("readmeUrl") or r.get("url")
        if url:
            lines.append(url)
        body = (r.get("contentMd") or r.get("snippet") or "").strip()
        lines.append(body[:MAX_CONTENT_CHARS] if body else "(no content)")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    query = " ".join(args).strip()
    if not query:
        print('usage: web_github_search.py "<query>" [--json]', file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/research/search/github", method="POST",
                       body={"query": query})
    except fc.FcError as e:
        print(f"GITHUB SEARCH FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    results = data.get("results")
    if results is None:
        payload = data.get("data") if isinstance(data.get("data"), dict) \
            else data
        results = payload.get("results")
    if not isinstance(results, list):
        results = []
    print(fmt_github(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
