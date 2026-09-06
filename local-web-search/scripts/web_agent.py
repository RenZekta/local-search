#!/usr/bin/env python3
"""Start an asynchronous Firecrawl research agent job (the firecrawl_agent
MCP tool): give it a prompt, optional seed URLs, and read the result later
with web_agent_status.py.

Usage:
    python web_agent.py "<prompt>" [seed_url ...] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

The first argument is the research prompt (quote it); any further positional
arguments are seed URLs the agent should start from. This call only STARTS
the job and prints its ID — the research itself commonly takes several
minutes, so poll the job until it is completed or failed:

    python web_agent_status.py <id>

`--json` prints the raw API response instead of the summary.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/agent")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print('usage: web_agent.py "<prompt>" [seed_url ...] [--json]',
              file=sys.stderr)
        return 2
    prompt = args[0]
    urls, as_json = [], False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            urls.append(a)
        i += 1

    body = {"prompt": prompt}
    if urls:
        body["urls"] = urls

    try:
        data = fc.call("/v1/agent", method="POST", body=body)
    except fc.FcError as e:
        print(f"AGENT START FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    job_id = payload.get("id") or data.get("id")
    if not job_id:
        print("AGENT START FAILED: the API did not return a job id. Response:",
              file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1
    print(f"Agent job started: {job_id}")
    if urls:
        print(f"Seed URLs: {', '.join(urls)}")
    print("Research commonly takes several minutes — poll with:")
    print(f"    python web_agent_status.py {job_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
