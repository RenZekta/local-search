#!/usr/bin/env python3
"""Find research papers related to seed papers via the Firecrawl citation
graph (the firecrawl_research_related_papers MCP tool).

Usage:
    python web_research_related.py <seedId> [seedId ...] --intent "what to rank for"
                                   [--mode similar|citers|references] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

One to ten seed paper IDs (positional); the first is the primary seed, the
rest are anchors. `--intent` (required) is a short natural-language
description that ranks the candidates. `--mode` defaults to `similar`
(co-citation / bibliographic coupling); `citers` returns papers citing a
seed, `references` papers cited by a seed.

Prints the ranked candidates like web_research_search.py, then
`(poolSize=N)` and any `note:` from the API. `--json` prints the raw API
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
import web_research_search  # sibling: shared paper formatters

ENDPOINT = fc.url("/v1/research/related")

MODES = ("similar", "citers", "references")


def main() -> int:
    args = sys.argv[1:]
    seeds, intent, mode, as_json = [], None, None, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--intent" and i + 1 < len(args):
            i += 1
            intent = args[i]
        elif a == "--mode" and i + 1 < len(args):
            i += 1
            mode = args[i]
            if mode not in MODES:
                print(f"invalid --mode: {mode} (one of {', '.join(MODES)})",
                      file=sys.stderr)
                return 2
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            seeds.append(a)
        i += 1

    if not seeds or not intent:
        print('usage: web_research_related.py <seedId> [seedId ...] '
              '--intent "what to rank for" '
              '[--mode similar|citers|references] [--json]', file=sys.stderr)
        return 2
    if not 1 <= len(seeds) <= 10:
        print("provide one to ten seed paper IDs (first is the primary seed)",
              file=sys.stderr)
        return 2

    body = {"seed_ids": seeds, "intent": intent}
    if mode:
        body["mode"] = mode

    try:
        data = fc.call("/v1/research/related", method="POST", body=body)
    except fc.FcError as e:
        print(f"RESEARCH RELATED FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    print(web_research_search.fmt_hits(
        web_research_search.extract_results(data)))
    pool_size = payload.get("poolSize") or 0
    print(f"(poolSize={pool_size})")
    note = payload.get("note")
    if note:
        print(f"note: {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
