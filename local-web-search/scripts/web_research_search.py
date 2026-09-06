#!/usr/bin/env python3
"""Search research papers via the Firecrawl research index (the
firecrawl_research_search_papers MCP tool): paper metadata and abstracts
across biomedical, life-science, and clinical literature (PubMed, bioRxiv,
medRxiv) alongside arXiv and other scientific sources.

Usage:
    python web_research_search.py "<query>" [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the ranked papers exactly like the MCP tool does — for each paper:

    ## [paperId] title
    Authors: name; name; +N more
    abstract (up to 600 chars)

Several distinct framings of the same question surface different papers.
Inspect one paper with web_research_inspect.py. `--json` prints the raw API
response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/research/search/papers")

MAX_AUTHORS = 15
MAX_ABSTRACT_CHARS = 600
MAX_AFFIL_CHARS = 60
MAX_AUTHORS_LINE_CHARS = 400


def display_id(paper):
    return paper.get("primaryId") or paper.get("paperId") or "missing-primary-id"


def fmt_authors(authors):
    """`Authors: a; b (affiliation); +N more` or None (mirrors the MCP tool)."""
    if not authors:
        return None
    if isinstance(authors, str):
        names = [s.strip() for s in authors.split(",") if s.strip()]
        if not names:
            return None
        total, shown = len(names), names[:MAX_AUTHORS]
    else:
        if not isinstance(authors, list) or not authors:
            return None
        total = len(authors)
        shown = []
        for a in authors[:MAX_AUTHORS]:
            if isinstance(a, dict):
                aff = (a.get("affiliation") or "").strip()
                name = a.get("name") or "?"
                shown.append("{} ({})".format(name, aff[:MAX_AFFIL_CHARS])
                             if aff else name)
            else:
                shown.append(str(a))
    extra = "; +{} more".format(total - MAX_AUTHORS) if total > MAX_AUTHORS \
        else ""
    return ("Authors: " + "; ".join(shown) + extra)[:MAX_AUTHORS_LINE_CHARS]


def fmt_hits(results):
    """Format ranked paper results (mirrors the MCP tool's formatter)."""
    if not results:
        return "(no results)"
    blocks = []
    for r in results:
        if not isinstance(r, dict):
            blocks.append(str(r))
            continue
        lines = ["## [{}] {}".format(display_id(r),
                                     r.get("title") or "(untitled)")]
        authors = fmt_authors(r.get("authors"))
        if authors:
            lines.append(authors)
        abstract = (r.get("abstract") or "(no abstract)")
        abstract = " ".join(abstract.split())[:MAX_ABSTRACT_CHARS]
        lines.append(abstract)
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def extract_results(data):
    """Find the paper-result list in the API response."""
    results = data.get("results")
    if isinstance(results, list):
        return results
    payload = data.get("data")
    if isinstance(payload, dict) and isinstance(payload.get("results"), list):
        return payload["results"]
    if isinstance(data, list):
        return data
    return []


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    query = " ".join(args).strip()
    if not query:
        print('usage: web_research_search.py "<query>" [--json]', file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/research/search/papers", method="POST",
                       body={"query": query})
    except fc.FcError as e:
        print(f"RESEARCH SEARCH FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(fmt_hits(extract_results(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
