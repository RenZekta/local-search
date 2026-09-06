#!/usr/bin/env python3
"""Get the progress or final results of a Firecrawl research agent job (the
firecrawl_agent_status MCP tool), started with web_agent.py.

Usage:
    python web_agent_status.py <id> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints `Agent <id>: <status>`. A `processing`/`active` status is non-terminal
— check again after 15-30 s. When the job is `completed`, the research result
follows (steps, sources, and the final answer/report as returned by the API);
`failed` jobs print the available error details and exit 1. `--json` prints
the raw API response instead.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/agent")


def print_result(result, indent=0):
    """Recursively print the agent result in a readable outline."""
    pad = " " * indent
    if isinstance(result, dict):
        for key, val in result.items():
            if isinstance(val, (dict, list)):
                print(f"{pad}{key}:")
                print_result(val, indent + 2)
            else:
                text = str(val)
                if len(text) > 4000:
                    text = text[:4000] + f"\n{pad}[... truncated ...]"
                print(f"{pad}{key}: {text}")
    elif isinstance(result, list):
        for n, item in enumerate(result, 1):
            print(f"{pad}{n}.")
            print_result(item, indent + 2)
    else:
        text = str(result)
        if len(text) > 4000:
            text = text[:4000] + f"\n{pad}[... truncated ...]"
        print(pad + text)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_agent_status.py <id> [--json]", file=sys.stderr)
        return 2
    job_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/agent/" + str(job_id), method="GET")
    except fc.FcError as e:
        print(f"AGENT STATUS FAILED for {job_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0 if data.get("status") != "failed" else 1

    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    status = str(payload.get("status") or data.get("status") or "unknown")
    print(f"Agent {job_id}: {status}")
    if status not in ("completed", "failed", "cancelled", "stopped"):
        print("(non-terminal — check again after 15-30 s)")
        return 0
    result = payload.get("result")
    if result is None:
        result = data.get("result")
    if result is not None:
        print()
        print_result(result)
    elif status == "failed":
        error = payload.get("error") or data.get("error")
        print(f"error: {error or '(no details returned)'}")
    return 0 if status == "completed" else 1


if __name__ == "__main__":
    sys.exit(main())
