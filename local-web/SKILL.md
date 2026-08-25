---
name: local-web
description: Search the web and read web pages through the local private stack — SearXNG and Firecrawl on localhost (ports read from the local-search .env, defaults 9990/9991). No API keys, no external services, no MCP tools. Use whenever the user asks about anything current, recent, or you are unsure about: news, events, latest versions or releases, documentation, facts to verify, "what do you know about X" questions — even when they don't explicitly say "search the web".
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
with the Bash tool using `python`. The services live in Docker containers;
`ensure_stack.py` starts the Docker engine and the containers automatically
if they aren't running (and never stops them — stopping is the user's job,
via Stop.bat / stop.sh).

## Workflow

1. **Make sure the stack is running** — do this once before the first search:

   ```bash
   python "<skill-base-dir>/scripts/ensure_stack.py"
   ```

   This is fast when the stack is already up. If it's down, the script starts
   the Docker engine (if it's off) and the containers (the same command
   Run.bat / run.sh run) and waits until both endpoints answer. Give the Bash
   call a 10-minute timeout (engine boot + container boot); only a first-ever
   start (pulling ~3 GB of images) can exceed that. If the script reports it
   could not launch the Docker engine at all, ask the user to start Docker
   Desktop, then re-run the script.

2. **Find URLs** — search the web:

   ```bash
   python "<skill-base-dir>/scripts/web_search.py" "your query here"
   ```

   Prints the top results as `title / url / ~300-char snippet`.
   Useful options: `--limit 10`, `--time-range day|week|month`,
   `--categories it,news,general`.

3. **Read the pages** — scrape the 1–3 most relevant result URLs for full text:

   ```bash
   python "<skill-base-dir>/scripts/web_scrape.py" "https://example.com/article"
   ```

   Prints clean Markdown (truncated at 20,000 chars by default; raise with
   `--max-chars`). Only ever scrape URLs that the search results actually
   returned — never invent or guess URLs.

4. **Answer with citations** — back each factual claim with the URL you read.

## Error handling

- If a search or scrape fails, retry **once** with a different query (search)
  or a different result URL (scrape).
- If requests fail with connection errors, the stack isn't running (or went
  down). Run `python "<skill-base-dir>/scripts/ensure_stack.py"` — it starts
  the Docker engine (if needed) and the containers, and waits until they
  answer — then retry the failed operation once. Only if the script reports
  it could not launch the engine at all should you ask the user to start
  Docker Desktop manually.
- Only if the script reports it could not find the local-search install
  folder: ask the user where that folder is, then re-run the script with
  `LOCAL_SEARCH_DIR=<that path>`. Don't do this preemptively — the folder is
  normally detected automatically (from the compose label on the running
  containers, the path recorded by the local-search installer, or from
  ~/local-search).
- Scrape output is long. Extract only the parts you need for the answer; don't
  paste whole pages back to the user.
