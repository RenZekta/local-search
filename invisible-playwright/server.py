#!/usr/bin/env python3
"""
Invisible Playwright service for Local Search.

A drop-in replacement for Firecrawl's playwright-service: it speaks the same
two HTTP routes, so Firecrawl only needs PLAYWRIGHT_MICROSERVICE_URL pointed at
it, but the pages are rendered by invisible-playwright
(https://github.com/oss-invisible/playwright), a patched Firefox whose
fingerprint is generated inside the engine instead of being injected through
JavaScript.

Routes
  GET  /health   200 {"status": "healthy", ...}  |  503 {"status": "unhealthy", ...}
  POST /scrape   body: {url, wait_after_load, timeout, headers, check_selector,
                        skip_tls_verification}
                 200 {content, pageStatusCode, contentType, pageError?}
                 400 {"error": "URL is required" | "Invalid URL"}
                 500 {"error": "An error occurred while fetching the page.", "detail": ...}
                 A target the SSRF guard refuses answers 200 with
                 {content: "", pageStatusCode: 403, pageError: ...}, exactly like
                 Firecrawl's own service.

Environment (all optional)
  PORT                    listen port (default 3000)
  MAX_CONCURRENT_PAGES    scrapes running at once (default 4; Firefox is heavy)
  BLOCK_MEDIA             "true" aborts image/media requests (default false)
  BLOCK_ADS               "true" aborts a short list of ad/tracker hosts (default false)
  ALLOW_LOCAL_WEBHOOKS    "true" turns the private-address (SSRF) guard off
  PROXY_SERVER / PROXY_USERNAME / PROXY_PASSWORD   upstream proxy (http/https/socks)
  INVPW_SEED              fixed fingerprint seed (default: random per start)
  INVPW_TIMEZONE          fixed IANA timezone (default: derived from the exit IP; if that
                          lookup fails and NO proxy is set the service starts with UTC,
                          with a proxy it refuses to start rather than mismatch the IP)
  INVPW_LOCALE            fixed locale tag (default "auto")
  INVPW_HONOR_USER_AGENT  "true" applies a User-Agent header sent by the caller.
                          Off by default: the engine already presents a coherent
                          user agent, and overriding it breaks that coherence.

Requests are only intercepted (page.route) when BLOCK_MEDIA, BLOCK_ADS or the
SSRF guard needs it, so the default configuration touches nothing between the
page and the network.

Compatible with Python 3.8+ (the container uses 3.11+).
"""
from __future__ import annotations

import asyncio
import http
import ipaddress
import logging
import os
import sys
import time
from contextlib import AsyncExitStack
from typing import Any, Awaitable, Callable, Dict, List, Optional, Tuple
from urllib.parse import urlparse

from aiohttp import web

log = logging.getLogger("invisible-playwright-service")

GENERIC_ERROR = "An error occurred while fetching the page."

# A short, conservative list. Only used when BLOCK_ADS=true.
AD_HOSTS = (
    "doubleclick.net", "googlesyndication.com", "googleadservices.com",
    "adservice.google.com", "google-analytics.com", "adsrvr.org", "adnxs.com",
    "taboola.com", "outbrain.com", "criteo.com", "scorecardresearch.com",
    "hotjar.com", "amazon-adsystem.com", "moatads.com", "quantserve.com",
)


# ----------------------------------------------------------------------------
# configuration
# ----------------------------------------------------------------------------
def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _env_int(name: str, default: int, minimum: int = 1) -> int:
    raw = os.environ.get(name)
    try:
        value = int(raw) if raw not in (None, "") else default
    except ValueError:
        value = default
    return max(minimum, value)


def _proxy_from_env() -> Optional[Dict[str, str]]:
    server = (os.environ.get("PROXY_SERVER") or "").strip()
    if not server:
        return None
    if "://" not in server:
        server = "http://" + server
    proxy = {"server": server}
    user = os.environ.get("PROXY_USERNAME") or ""
    password = os.environ.get("PROXY_PASSWORD") or ""
    if user:
        proxy["username"] = user
    if password:
        proxy["password"] = password
    return proxy


class Config:
    def __init__(self) -> None:
        self.port = _env_int("PORT", 3000)
        self.max_pages = _env_int("MAX_CONCURRENT_PAGES", 4)
        self.block_media = _env_bool("BLOCK_MEDIA", False)
        self.block_ads = _env_bool("BLOCK_ADS", False)
        self.ssrf_guard = not _env_bool("ALLOW_LOCAL_WEBHOOKS", False)
        self.honor_user_agent = _env_bool("INVPW_HONOR_USER_AGENT", False)
        self.proxy = _proxy_from_env()
        seed = (os.environ.get("INVPW_SEED") or "").strip()
        self.seed: Optional[int] = int(seed) if seed.lstrip("-").isdigit() else None
        self.timezone = (os.environ.get("INVPW_TIMEZONE") or "").strip()
        self.locale = (os.environ.get("INVPW_LOCALE") or "").strip() or "auto"
        self.fallback_timezone = "UTC"
        # start the browser when the app starts (tests turn this off)
        self.eager_start = True

    @property
    def intercept(self) -> bool:
        return self.block_media or self.block_ads or self.ssrf_guard


# ----------------------------------------------------------------------------
# URL / SSRF helpers
# ----------------------------------------------------------------------------
def _is_public_address(addr: str) -> bool:
    try:
        ip = ipaddress.ip_address(addr.split("%", 1)[0])
    except ValueError:
        return False
    return ip.is_global and not ip.is_multicast


async def resolve_host(host: str) -> List[str]:
    """Every address a hostname resolves to ([] when it does not resolve)."""
    loop = asyncio.get_running_loop()
    try:
        infos = await loop.getaddrinfo(host, None)
    except OSError:
        return []
    return sorted({info[4][0] for info in infos})


async def host_is_public(host: str) -> bool:
    """True when every address the host resolves to is a public unicast one."""
    if not host:
        return False
    try:
        ipaddress.ip_address(host)
        return _is_public_address(host)
    except ValueError:
        pass
    addrs = await resolve_host(host)
    return bool(addrs) and all(_is_public_address(a) for a in addrs)


def parse_target(url: Any) -> Tuple[Optional[Any], Optional[str]]:
    """-> (parsed, problem). problem is 'invalid' or 'scheme' when unusable."""
    if not isinstance(url, str) or not url.strip():
        return None, "invalid"
    try:
        parsed = urlparse(url.strip())
    except ValueError:
        return None, "invalid"
    if not parsed.scheme:
        return None, "invalid"
    if parsed.scheme not in ("http", "https"):
        return parsed, "scheme"
    if not parsed.hostname:
        return None, "invalid"
    return parsed, None


def parse_cookie_header(value: str) -> List[Tuple[str, str]]:
    pairs = []
    for part in value.split(";"):
        if "=" not in part:
            continue
        name, _, val = part.partition("=")
        name = name.strip()
        if name:
            pairs.append((name, val.strip()))
    return pairs


def cookie_domains(host: str) -> List[str]:
    """Domains a caller-supplied cookie is stored under.

    The host itself, plus the parent of a leading 'www.' so a redirect from
    www.example.com to example.com (or back) keeps the cookie. Cookies are never
    widened to the last two labels: that would be a public suffix for hosts like
    example.co.uk, and browsers refuse those.
    """
    try:
        ipaddress.ip_address(host)
        return [host]
    except ValueError:
        pass
    domains = ["." + host]
    if host.startswith("www.") and host.count(".") >= 2:
        domains.append("." + host[4:])
    return domains


def is_ad_host(host: str) -> bool:
    host = host.lower()
    return any(host == h or host.endswith("." + h) for h in AD_HOSTS)


def status_phrase(status: int) -> str:
    try:
        return http.HTTPStatus(status).phrase
    except ValueError:
        return "HTTP " + str(status)


# ----------------------------------------------------------------------------
# browser lifecycle
# ----------------------------------------------------------------------------
BrowserFactory = Callable[[AsyncExitStack, Config], Awaitable[Any]]


async def launch_invisible(stack: AsyncExitStack, cfg: Config) -> Any:
    """Start invisible-playwright and return its Playwright Browser."""
    from invisible_playwright.async_api import InvisiblePlaywright

    kwargs: Dict[str, Any] = {"headless": True, "locale": cfg.locale}
    if cfg.seed is not None:
        kwargs["seed"] = cfg.seed
    if cfg.proxy:
        kwargs["proxy"] = cfg.proxy
    if cfg.timezone:
        kwargs["timezone"] = cfg.timezone
    try:
        return await stack.enter_async_context(InvisiblePlaywright(**kwargs))
    except Exception as exc:  # noqa: BLE001
        if cfg.timezone or cfg.proxy:
            # An explicit timezone has nothing to fall back to. Behind a proxy the
            # timezone MUST match the proxy's exit IP and the engine refuses to
            # guess, so a failure here is reported, never papered over with UTC.
            raise
        # No proxy: "auto" derives the timezone from this machine's public IP and
        # needs a GeoIP database; on a cold cache with no route to GitHub that
        # fails. A fixed timezone keeps the service up, at the cost of one
        # fingerprint detail (the timezone then may not match the IP's location).
        log.warning("launch with automatic timezone failed (%s); retrying with %s",
                    exc, cfg.fallback_timezone)
        kwargs["timezone"] = cfg.fallback_timezone
        return await stack.enter_async_context(InvisiblePlaywright(**kwargs))


class BrowserHolder:
    def __init__(self, cfg: Config, factory: BrowserFactory) -> None:
        self._cfg = cfg
        self._factory = factory
        self._browser: Any = None
        self._stack: Optional[AsyncExitStack] = None
        self._lock = asyncio.Lock()

    @staticmethod
    def _connected(browser: Any) -> bool:
        check = getattr(browser, "is_connected", None)
        try:
            return bool(check()) if callable(check) else True
        except Exception:  # noqa: BLE001
            return False

    async def get(self) -> Any:
        async with self._lock:
            if self._browser is not None and self._connected(self._browser):
                return self._browser
            if self._browser is not None:
                log.warning("the browser went away; starting a new one")
            await self._close_locked()
            stack = AsyncExitStack()
            try:
                browser = await self._factory(stack, self._cfg)
            except BaseException:
                try:
                    await stack.aclose()
                except Exception:  # noqa: BLE001
                    pass
                raise
            self._stack, self._browser = stack, browser
            log.info("browser ready")
            return browser

    async def _close_locked(self) -> None:
        stack, self._stack, self._browser = self._stack, None, None
        if stack is not None:
            try:
                await stack.aclose()
            except Exception as exc:  # noqa: BLE001
                log.warning("error while closing the browser: %s", exc)

    async def close(self) -> None:
        async with self._lock:
            await self._close_locked()


# ----------------------------------------------------------------------------
# request handling
# ----------------------------------------------------------------------------
class Service:
    def __init__(self, cfg: Config, factory: BrowserFactory) -> None:
        self.cfg = cfg
        self.holder = BrowserHolder(cfg, factory)
        self.sem = asyncio.Semaphore(cfg.max_pages)
        self.active = 0

    # -- /health -------------------------------------------------------------
    async def health(self, request: web.Request) -> web.Response:
        try:
            browser = await self.holder.get()
            context = await browser.new_context()
            try:
                page = await context.new_page()
                await page.close()
            finally:
                await context.close()
            return web.json_response({
                "status": "healthy",
                "maxConcurrentPages": self.cfg.max_pages,
                "activePages": self.active,
            })
        except Exception as exc:  # noqa: BLE001
            log.warning("health check failed: %s", exc)
            return web.json_response({"status": "unhealthy", "error": str(exc)[:300]}, status=503)

    # -- /scrape -------------------------------------------------------------
    async def scrape(self, request: web.Request) -> web.Response:
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001
            body = None
        if not isinstance(body, dict):
            return web.json_response({"error": "URL is required"}, status=400)

        url = body.get("url")
        if not url:
            return web.json_response({"error": "URL is required"}, status=400)
        parsed, problem = parse_target(url)
        if problem == "invalid":
            return web.json_response({"error": "Invalid URL"}, status=400)
        if problem == "scheme":
            return self._blocked("Only http and https URLs can be fetched.")

        wait_after_load = self._int(body.get("wait_after_load"), 0, 0, 120000)
        timeout = self._int(body.get("timeout"), 15000, 1, 600000)
        headers = body.get("headers") if isinstance(body.get("headers"), dict) else {}
        check_selector = body.get("check_selector") or None
        skip_tls = bool(body.get("skip_tls_verification"))

        host = (parsed.hostname or "").lower()
        if self.cfg.ssrf_guard and not await host_is_public(host):
            return self._blocked("Requests to private or unresolvable addresses are not allowed.")

        # one slow page can never hold more than the navigation budget plus slack
        budget = (timeout + wait_after_load) / 1000.0 + 30.0
        started = time.monotonic()
        async with self.sem:
            self.active += 1
            try:
                return await asyncio.wait_for(
                    self._fetch(parsed, str(url).strip(), wait_after_load, timeout,
                                headers, check_selector, skip_tls),
                    timeout=budget)
            except asyncio.TimeoutError:
                log.warning("scrape of %s timed out after %.0fs", self._safe(parsed), budget)
                return self._failed("timed out")
            finally:
                self.active -= 1
                log.info("scrape %s took %.1fs", self._safe(parsed), time.monotonic() - started)

    async def _fetch(self, parsed: Any, url: str, wait_after_load: int, timeout: int,
                     headers: Dict[str, Any], check_selector: Optional[str],
                     skip_tls: bool) -> web.Response:
        blocked: List[str] = []
        context = None
        try:
            browser = await self.holder.get()
            ctx_kwargs: Dict[str, Any] = {}
            if skip_tls:
                ctx_kwargs["ignore_https_errors"] = True
            ua = self._header(headers, "user-agent")
            if ua and self.cfg.honor_user_agent:
                ctx_kwargs["user_agent"] = ua
            # Extra headers MUST be given when the context is created: this engine
            # does not implement BrowserContext.set_extra_http_headers() ("not
            # wired yet"), so calling it afterwards fails every request that
            # carries one. User-Agent and Cookie are handled separately.
            extra = {str(k): str(v) for k, v in headers.items()
                     if str(k).lower() not in ("user-agent", "cookie")}
            if extra:
                ctx_kwargs["extra_http_headers"] = extra
            context = await browser.new_context(**ctx_kwargs)

            cookie = self._header(headers, "cookie")
            if cookie:
                cookies = []
                for name, value in parse_cookie_header(cookie):
                    for domain in cookie_domains((parsed.hostname or "").lower()):
                        cookies.append({"name": name, "value": value, "domain": domain, "path": "/"})
                if cookies:
                    await context.add_cookies(cookies)


            if self.cfg.intercept:
                await context.route("**/*", self._make_router(blocked))

            page = await context.new_page()
            page.set_default_timeout(timeout)
            try:
                response = await page.goto(url, wait_until="load", timeout=timeout)
            except Exception:
                if blocked:
                    return self._blocked(blocked[0])
                raise
            if blocked and response is None:
                return self._blocked(blocked[0])

            if wait_after_load > 0:
                await page.wait_for_timeout(wait_after_load)
            if check_selector:
                await page.wait_for_selector(str(check_selector), timeout=timeout)

            status = response.status if response is not None else 200
            content_type = None
            if response is not None:
                content_type = (response.headers or {}).get("content-type")
            lowered = (content_type or "").lower()
            if "application/json" in lowered or "text/plain" in lowered:
                content = await response.text()
            else:
                content = await page.content()

            payload: Dict[str, Any] = {
                "content": content,
                "pageStatusCode": status,
                "contentType": content_type,
            }
            if status != 200:
                payload["pageError"] = status_phrase(status)
            return web.json_response(payload)
        except Exception as exc:  # noqa: BLE001
            if blocked:
                return self._blocked(blocked[0])
            log.warning("scrape of %s failed: %s", self._safe(parsed), exc)
            return self._failed(str(exc))
        finally:
            if context is not None:
                try:
                    await context.close()
                except Exception:  # noqa: BLE001
                    pass

    def _make_router(self, blocked: List[str]) -> Callable[[Any], Awaitable[None]]:
        cfg = self.cfg

        async def route(route_obj: Any) -> None:
            request = route_obj.request
            try:
                target = urlparse(request.url)
                host = (target.hostname or "").lower()
                if cfg.ssrf_guard and target.scheme in ("http", "https") \
                        and not await host_is_public(host):
                    blocked.append("Requests to private or unresolvable addresses are not allowed.")
                    await route_obj.abort("blockedbyclient")
                    return
                if cfg.block_ads and is_ad_host(host):
                    await route_obj.abort("blockedbyclient")
                    return
                if cfg.block_media and request.resource_type in ("image", "media"):
                    await route_obj.abort("blockedbyclient")
                    return
            except Exception as exc:  # noqa: BLE001
                log.debug("route check failed, letting the request through: %s", exc)
            await route_obj.continue_()

        return route

    # -- small helpers -------------------------------------------------------
    @staticmethod
    def _int(value: Any, default: int, lo: int, hi: int) -> int:
        try:
            number = int(float(value)) if value not in (None, "") else default
        except (TypeError, ValueError):
            number = default
        return max(lo, min(hi, number))

    @staticmethod
    def _header(headers: Dict[str, Any], name: str) -> Optional[str]:
        for key, value in headers.items():
            if str(key).lower() == name and value not in (None, ""):
                return str(value)
        return None

    @staticmethod
    def _safe(parsed: Any) -> str:
        return "%s://%s%s" % (parsed.scheme, parsed.netloc, parsed.path)  # never log the query

    @staticmethod
    def _blocked(message: str) -> web.Response:
        return web.json_response({"content": "", "pageStatusCode": 403, "pageError": message})

    @staticmethod
    def _failed(detail: str) -> web.Response:
        return web.json_response({"error": GENERIC_ERROR, "detail": detail[:300]}, status=500)


# ----------------------------------------------------------------------------
# application
# ----------------------------------------------------------------------------
def create_app(cfg: Optional[Config] = None, browser_factory: Optional[BrowserFactory] = None) -> web.Application:
    cfg = cfg or Config()
    app = web.Application()
    holder: Dict[str, Service] = {}

    async def on_startup(_app: web.Application) -> None:
        # asyncio primitives are created here, inside the running loop
        service = Service(cfg, browser_factory or launch_invisible)
        holder["service"] = service
        if cfg.eager_start:
            try:
                await service.holder.get()
            except Exception as exc:  # noqa: BLE001
                log.error("could not start the browser: %s", exc)
                raise

    async def on_cleanup(_app: web.Application) -> None:
        service = holder.get("service")
        if service is not None:
            await service.holder.close()

    async def health(request: web.Request) -> web.Response:
        return await holder["service"].health(request)

    async def scrape(request: web.Request) -> web.Response:
        return await holder["service"].scrape(request)

    app.router.add_get("/health", health)
    app.router.add_post("/scrape", scrape)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    app["service_holder"] = holder
    return app


def main() -> int:
    logging.basicConfig(level=os.environ.get("LOGGING_LEVEL", "INFO").upper(),
                        format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
    cfg = Config()
    if cfg.proxy is None:
        log.warning("no PROXY_SERVER set: requests leave from this machine's own address")
    log.info("starting on port %d (max %d pages, ssrf guard %s)",
             cfg.port, cfg.max_pages, "on" if cfg.ssrf_guard else "off")
    try:
        web.run_app(create_app(cfg), host="0.0.0.0", port=cfg.port, print=None, access_log=None)
    except Exception as exc:  # noqa: BLE001
        log.error("startup failed: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
