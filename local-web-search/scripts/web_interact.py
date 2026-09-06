#!/usr/bin/env python3
"""Interact with a scraped page through a live Firecrawl browser session
(the firecrawl_interact MCP tool): navigate, click controls, fill fields, or
run browser code.

Usage:
    python web_interact.py (--scrape-id ID | --url URL)
                           (--prompt TEXT | --code TEXT [--language bash|python|node])
                           [--timeout S] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Provide EITHER --scrape-id (reuse a previous scrape's session) or --url
(open a fresh session), and EITHER --prompt (natural-language instructions)
or --code (with --language, default bash). NOTE: this acts on the LIVE site —
actions such as form submission can create persistent external side effects.

Prints the API's JSON response: execution output, stdout/stderr, exit
status, and the session viewing URLs. `--json` prints it compact on one line
instead of pretty-printed.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/interact")

LANGUAGES = ("bash", "python", "node")


def main() -> int:
    args = sys.argv[1:]
    scrape_id, url = None, None
    prompt, code, language = None, None, None
    timeout, as_json = None, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--scrape-id" and i + 1 < len(args):
            i += 1
            scrape_id = args[i]
        elif a == "--url" and i + 1 < len(args):
            i += 1
            url = args[i]
        elif a == "--prompt" and i + 1 < len(args):
            i += 1
            prompt = args[i]
        elif a == "--code" and i + 1 < len(args):
            i += 1
            code = args[i]
        elif a == "--language" and i + 1 < len(args):
            i += 1
            language = args[i]
            if language not in LANGUAGES:
                print(f"invalid --language: {language} "
                      f"(one of {', '.join(LANGUAGES)})", file=sys.stderr)
                return 2
        elif a == "--timeout" and i + 1 < len(args):
            i += 1
            try:
                timeout = int(args[i])
            except ValueError:
                print(f"invalid --timeout: {args[i]}", file=sys.stderr)
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

    if bool(scrape_id) == bool(url):
        print("provide exactly one of --scrape-id (reuse a scrape's session) "
              "or --url (open a new session), not both", file=sys.stderr)
        return 2
    if not prompt and not code:
        print("provide either --prompt (natural language) or --code "
              "(executable, with --language)", file=sys.stderr)
        return 2
    if language and not code:
        print("--language can only be used together with --code",
              file=sys.stderr)
        return 2

    body = {}
    if scrape_id:
        body["scrapeId"] = scrape_id
    else:
        body["url"] = url
    if prompt:
        body["prompt"] = prompt
    if code:
        body["code"] = code
        body["language"] = language or "bash"
    if timeout is not None:
        body["timeout"] = timeout

    try:
        data = fc.call("/v1/interact", method="POST", body=body)
    except fc.FcError as e:
        print(f"INTERACT FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    print(json.dumps(data) if as_json else json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
