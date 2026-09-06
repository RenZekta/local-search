#!/usr/bin/env python3
"""Parse a local document into markdown / HTML / links / a summary / targeted
answers / structured JSON (the firecrawl_parse MCP tool). Supported inputs
include common HTML, PDF, Word, RTF, OpenDocument, and spreadsheet files.

Usage:
    python web_parse.py <filePath> [--formats markdown,links,...] [--max-chars N]
                        [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once. You do NOT need to run ensure_stack.py first — just run the
script.

The file is uploaded to the local Firecrawl instance (it never leaves your
machine). `--formats` takes a comma-separated list from: markdown, html,
rawHtml, links, summary, json, query (default: markdown). Prints the parsed
content; with several formats each is printed under a `## <format>` header.
Markdown/HTML truncate at --max-chars chars (default 20000, like
web_scrape.py). `--json` prints the raw API response instead.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/parse")

FORMATS = ("markdown", "html", "rawHtml", "links", "summary", "json", "query")

# Extension -> MIME type for the upload (everything else is sent as a
# generic octet stream and Firecrawl sniffs the real type server-side).
MIME_TYPES = {
    ".html": "text/html", ".htm": "text/html",
    ".pdf": "application/pdf",
    ".doc": "application/msword",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".rtf": "application/rtf",
    ".odt": "application/vnd.oasis.opendocument.text",
    ".ods": "application/vnd.oasis.opendocument.spreadsheet",
    ".xls": "application/vnd.ms-excel",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".csv": "text/csv",
    ".txt": "text/plain",
    ".md": "text/markdown",
}

# Formats whose content is plain text and can be truncated safely.
TEXT_FORMATS = ("markdown", "html", "rawHtml", "summary", "query")


def content_type_for(path):
    return MIME_TYPES.get(os.path.splitext(path)[1].lower(),
                          "application/octet-stream")


def print_field(name, value, max_chars):
    """Print one parsed format under a header, truncating long text."""
    if name != "markdown":
        print(f"## {name}")
    if isinstance(value, list):
        for n, item in enumerate(value, 1):
            print(f"{n}. {item}")
        return
    if isinstance(value, (dict, bool, int, float)):
        print(json.dumps(value, indent=2))
        return
    text = str(value)
    if not text:
        print("(empty)")
        return
    if name in TEXT_FORMATS and len(text) > max_chars:
        text = text[:max_chars] + f"\n[... truncated at {max_chars} chars ...]"
    print(text)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_parse.py <filePath> [--formats markdown,links,...] "
              "[--max-chars N] [--json]", file=sys.stderr)
        return 2
    file_path = args[0]
    formats = ["markdown"]
    max_chars, as_json = 20000, False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--formats" and i + 1 < len(args):
            i += 1
            formats = [f.strip() for f in args[i].split(",") if f.strip()]
            bad = [f for f in formats if f not in FORMATS]
            if bad:
                print(f"invalid --formats value(s): {', '.join(bad)} "
                      f"(valid: {', '.join(FORMATS)})", file=sys.stderr)
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

    if not os.path.isfile(file_path):
        print(f"PARSE FAILED: no such file: {file_path}", file=sys.stderr)
        return 1

    options = {"formats": formats}
    fields = {"options": json.dumps(options),
              "contentType": content_type_for(file_path)}
    try:
        data = fc.call_form("/v1/parse", fields, file_path)
    except fc.FcError as e:
        print(f"PARSE FAILED for {file_path}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    printed = 0
    for fmt in formats:
        value = payload.get(fmt)
        if value is None:
            continue
        if printed:
            print()
        print_field(fmt, value, max_chars)
        printed += 1
    if not printed:
        print(f"PARSE RETURNED NO CONTENT for {file_path}", file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
