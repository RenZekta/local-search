---
name: local-web
description: Search the web and read web pages through the local private stack — SearXNG and Firecrawl on localhost (ports read from the local-search .env, defaults 9990/9991). No API keys, no external services, no MCP tools. The scripts auto-start the local Docker stack when it is down. Use whenever the user asks about anything current, recent, or you are unsure about: news, events, latest versions or releases, documentation, facts to verify, "what do you know about X" questions — even when they don't explicitly say "search the web".
---

# Local web research

This machine runs a private web-research stack on localhost:

- **SearXNG** — metasearch with a JSON API, at `http://localhost:9990` by default
- **Firecrawl** — turns any URL into clean Markdown, at `http://localhost:9991` by default

Everything stays local; no API keys are needed. The actual ports are read
from `SEARXNG_PORT` / `FIRECRAWL_PORT` in the local-search install folder's
`.env` (the same file the compose setup uses), so if custom ports were picked
at setup time, the scripts follow them automatically. Helper scripts (in this
skill's `scripts/` directory) do the HTTP and Docker work for you — run them
with the Bash tool using `python`. The services live in Docker containers.

**No warm-up step is needed.** If the stack is down, the scripts start the
Docker engine (if it's off) and the containers automatically (the same
command Run.bat / run.sh run), wait for them, and retry — they never stop
the stack (stopping is the user's job, via Stop.bat / stop.sh). Even in an
old conversation where the stack has since gone down, just call the search
or scrape script directly; it will bring everything back by itself.

## Workflow

1. **Search the web** — go straight ahead:

   ```bash
   python "<skill-base-dir>/scripts/web_search.py" "your query here"
   ```

   Prints the top results as `title / url / ~300-char snippet`.
   Useful options: `--limit 10`, `--time-range day|week|month`,
   `--categories it,news,general`.

   If the stack is down, the script reports `Stack unreachable ... starting
   it automatically` on stderr, boots it, and retries. Give the Bash call a
   10-minute timeout to allow for that (engine boot + container boot); only
   a first-ever start (pulling ~3 GB of images) can exceed it.

2. **Read the pages** — scrape the 1–3 most relevant result URLs for full text:

   ```bash
   python "<skill-base-dir>/scripts/web_scrape.py" "https://example.com/article"
   ```

   Prints clean Markdown (truncated at 20,000 chars by default; raise with
   `--max-chars`). Self-heals a down stack the same way. Only ever scrape
   URLs that the search results actually returned — never invent or guess
   URLs.

3. **Answer with citations** — back each factual claim with the URL you read.

`ensure_stack.py` is still available as an optional pre-flight check or
status report (`python "<skill-base-dir>/scripts/ensure_stack.py"`, add
`--check` to only report status and never start anything), but it is NOT
required before searching — the search/scrape scripts handle a down stack
themselves.

## Error handling

- If a search or scrape fails, retry **once** with a different query (search)
  or a different result URL (scrape).
- Connection errors are handled for you: the scripts start the Docker engine
  and the containers automatically, wait until they answer, and retry the
  request once. Only if a script reports it could not launch the engine at
  all (or the stack did not become ready) should you ask the user to start
  Docker Desktop manually, then retry.
- **Do not fall back to built-in or alternative web tools** when this stack
  has a problem — fix the stack (or ask the user) and retry, unless the user
  explicitly asks for an alternative.
- Only if a script reports it could not find the local-search install
  folder: ask the user where that folder is, then re-run the script with
  `LOCAL_SEARCH_DIR=<that path>`. Don't do this preemptively — the folder is
  normally detected automatically (from the compose label on the running
  containers, the path recorded by the local-search installer, or from
  ~/local-search).
- Scrape output is long. Extract only the parts you need for the answer; don't
  paste whole pages back to the user.
