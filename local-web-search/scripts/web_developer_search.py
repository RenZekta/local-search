#!/usr/bin/env python3
"""Search the Firecrawl developer index — built for coding agents, covering
GitHub issues, merged pull requests, repository READMEs, and curated
documentation sites (the firecrawl_developer_search MCP tool).

Usage:
    python web_developer_search.py "<query>" [--skills-only] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Use it for developer questions — code behaviour, a library or framework, an
API contract, an error message, or a known bug. `--skills-only` limits the
search to agent-skill files. Prints the ranked results exactly like the MCP
tool does — for each hit:

    ## [id] (kind) title
    https://...
    matched passages (up to 1200 chars, separated by ---)

`--json` prints the raw API response instead.

NOTE: developer search needs a Firecrawl account with developer-search
permissions (set FIRECRAWL_API_KEY, and
FIRECRAWL_API_URL=https://api.firecrawl.dev for the cloud API); the
self-hosted stack may not expose it.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/developer/search")

MAX_PASSAGE_CHARS = 1200


def fmt_developer(results):
    """Format ranked developer-index results (mirrors the MCP formatter)."""
    if not results:
        return "(no results)"
    blocks = []
    for r in results:
        if not isinstance(r, dict):
            blocks.append(str(r))
            continue
        rid = r.get("id") or "?"
        kind = str(rid).split(":", 1)[0]
        lines = ["## [{}]{} {}".format(rid, f" ({kind})" if kind else "",
                                       r.get("title") or "(untitled)")]
        if r.get("url"):
            lines.append(r["url"])
        passages = r.get("passages")
        body = ""
        if isinstance(passages, list):
            body = "\n---\n".join((p.get("text") or "")
                                  if isinstance(p, dict) else str(p)
                                  for p in passages).strip()
        lines.append(body[:MAX_PASSAGE_CHARS] if body else "(no content)")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json" and a != "--skills-only"]
    as_json = "--json" in sys.argv[1:]
    skills_only = "--skills-only" in sys.argv[1:]
    query = " ".join(args).strip()
    if not query:
        print('usage: web_developer_search.py "<query>" [--skills-only] [--json]',
              file=sys.stderr)
        return 2

    body = {"query": query}
    if skills_only:
        body["skills"] = "only"

    try:
        data = fc.call("/v1/developer/search", method="POST", body=body)
    except fc.FcError as e:
        print(f"DEVELOPER SEARCH FAILED: {e}", file=sys.stderr)
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
        results = payload.get("results") or payload.get("developer")
    if not isinstance(results, list):
        results = []
    print(fmt_developer(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
