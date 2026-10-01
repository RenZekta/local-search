#!/usr/bin/env python3
"""LLM extraction from one or more URLs via the local Firecrawl /v1/extract
endpoint.

Runs on the OpenAI-compatible LLM connected in the installer
(OPENAI_BASE_URL / OPENAI_API_KEY / MODEL_NAME in the install folder's
.env); the endpoint may be local or remote. Without a configured LLM the
endpoint fails with a "model not configured" error, which is expected and
not a stack failure.

Usage:
    python web_extract.py <url> [url ...] --prompt "what to extract" [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or
the containers are down), this script automatically starts them (the same
logic as ensure_stack.py / Run.bat) and retries the request. Connection
failures self-heal once; transient 429/5xx answers are retried with a short
backoff. You do NOT need to run ensure_stack.py first — just run the script.

Prints the extracted result (the `data` field of the response). `--json`
prints the full raw API response instead.
Exit codes: 0 success, 1 tool failure, 2 usage error.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal


def main() -> int:
    args = sys.argv[1:]
    urls = []
    prompt = None
    as_json = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--prompt" and i + 1 < len(args):
            i += 1
            prompt = args[i]
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            urls.append(a)
        i += 1

    if not urls or not prompt:
        print('usage: web_extract.py <url> [url ...] --prompt "what to extract" [--json]',
              file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/extract", method="POST",
                       body={"urls": urls, "prompt": prompt})
    except fc.FcError as e:
        print(f"EXTRACT FAILED for {', '.join(urls)}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if not data.get("success", True) and not data.get("data"):
        print("EXTRACT FAILED for {}: no data returned. Response: "
              .format(", ".join(urls)), file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
    else:
        print(json.dumps(data.get("data"), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
