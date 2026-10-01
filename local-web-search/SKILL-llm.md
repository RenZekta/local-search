
## LLM extraction

Extraction runs on the LLM connected in the installer (`OPENAI_BASE_URL` in
the install folder's `.env`). Run it on one or more pages:

```bash
python "<skill-base-dir>/scripts/web_extract.py" "https://example.com/article" \
  --prompt "Extract the author name and the first quote as JSON with fields author and quote"
```

Prints the extracted result as JSON (`--json` for the raw API response, which
includes token usage). Page text is sent to the connected LLM endpoint, so
whether it leaves the machine depends on where that endpoint runs. If the
endpoint is unreachable or the model is not configured the call fails; use
`web_scrape.py` for full-page text instead.

The local Firecrawl does NOT support per-page LLM extraction during a crawl
(`/v1/crawl` rejects `prompt` and `formats` keys). To get LLM-processed data
from a crawl, crawl first (`--limit N`), then run `web_extract.py` over the
pages you care about.
