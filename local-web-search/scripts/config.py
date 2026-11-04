"""Shared helpers for the local-web-search scripts: locating the local-search
install folder and the endpoints it is actually listening on, plus a quick
network diagnosis (diagnose_url) that explains WHY a site could not be loaded.

The ports are NOT assumed: they are read from the install folder's .env
file (the same one the compose setup and Run.bat / Update.bat use), so if
the user picked custom ports during setup, every script follows them.
Defaults mirror the compose file's ${VAR:-default} fallbacks:
SearXNG 9990, Firecrawl 9991.
"""
import errno
import ipaddress
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252). config.py is imported first by every entry-point
# script, so this covers the process even if this module is ever imported
# on its own. Skipped if PYTHONIOENCODING is already set — an explicit
# override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

# Compose file names accepted as "this is the install folder".
_COMPOSE_FILES = ("docker-compose.yml", "docker-compose.yaml",
                  "compose.yml", "compose.yaml")

# .env key -> default port (matches the defaults in docker-compose.yml).
_PORT_KEYS = {
    "searxng": ("SEARXNG_PORT", "9990"),
    "firecrawl": ("FIRECRAWL_PORT", "9991"),
}


def _has_compose_file(d):
    return d is not None and any(
        os.path.isfile(os.path.join(d, f)) for f in _COMPOSE_FILES
    )


ENGINES = ("podman", "docker")  # preference order: Podman wins when both exist


def installed_engines():
    """The container engines found on PATH, in preference order."""
    return [e for e in ENGINES if shutil.which(e)]


def engine_choice(install_dir=None):
    """Which container engine to use: (engine, auto).

    Same rule as engine.sh (the shell scripts):
      1. LOCAL_SEARCH_ENGINE=podman|docker in the environment (forced),
      2. LOCAL_SEARCH_ENGINE in the install folder's .env (the installer
         records its choice there),
      3. auto-detect: Podman when installed, otherwise Docker.
    `engine` is 'podman', 'docker' or None (nothing usable installed);
    `auto` is True when detection picked it, i.e. a fallback to the other
    engine is acceptable if this one cannot run.
    """
    forced = (os.environ.get("LOCAL_SEARCH_ENGINE") or "").strip().lower()
    want = forced or load_env(install_dir).get("LOCAL_SEARCH_ENGINE", "").strip().lower()
    if want in ENGINES:
        if shutil.which(want):
            return want, False
        if forced:  # an explicit override must not be silently ignored
            return None, False
    found = installed_engines()
    return (found[0] if found else None), True


def _labeled_install_dir():
    """The install folder per the compose label on the containers. Compose
    tags each container with the directory it was started from, so this
    finds the folder even though the skill itself lives elsewhere. A
    container engine (Podman or Docker) must be running."""
    forced = (os.environ.get("LOCAL_SEARCH_ENGINE") or "").strip().lower()
    # an explicit LOCAL_SEARCH_ENGINE means "only that engine"
    for engine in ([forced] if forced in ENGINES and shutil.which(forced) else installed_engines()):
        try:
            res = subprocess.run(
                [engine, "container", "ls", "-a", "-q",
                 "--filter", "label=com.docker.compose.service=searxng"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            ids = res.stdout.split()[:3]
        except (OSError, FileNotFoundError):
            continue
        for cid in ids:
            try:
                out = subprocess.run(
                    [engine, "container", "inspect", cid,
                     "--format",
                     '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            except (OSError, FileNotFoundError):
                continue
            p = out.stdout.strip()
            if p and os.path.isdir(p):
                return p
    return None


def _hinted_install_dir():
    """The install path recorded by the local-search installer when it
    copied this skill (install-dir.txt next to SKILL.md). This works even
    when the container engine is down and the install folder is not in the
    default location. Returns None when there is no hint file (e.g. the
    skill was installed standalone from the local-web-search repo)."""
    hint_file = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             os.pardir, "install-dir.txt")
    try:
        with open(hint_file, encoding="utf-8") as fh:
            path = fh.read().strip().rstrip("\\/").strip()
        return path or None
    except OSError:
        return None


def find_install_dir():
    """The local-search install folder (holds the compose file), or None.

    Looked up in order:
      1. the LOCAL_SEARCH_DIR env var (explicit override),
      2. the compose label on the containers (an engine must be running),
      3. install-dir.txt recorded by the local-search installer,
      4. ~/local-search (the installer's default location).
    """
    for d in (os.environ.get("LOCAL_SEARCH_DIR"),
              _labeled_install_dir(),
              _hinted_install_dir(),
              os.path.expanduser("~/local-search")):
        if d and _has_compose_file(d):
            return d
    return None


def load_env(install_dir):
    """The install folder's .env as a dict (empty dict if missing/invalid)."""
    values = {}
    if not install_dir:
        return values
    try:
        with open(os.path.join(install_dir, ".env"), encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                values[key.strip()] = val.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def endpoints(install_dir=None):
    """{'searxng': 'http://localhost:<port>', 'firecrawl': '...'}, with the
    ports taken from the install folder's .env (defaults 9990/9991)."""
    values = load_env(install_dir)
    urls = {}
    for name, (key, default) in _PORT_KEYS.items():
        port = values.get(key)
        if not port or not port.isdigit():
            port = default
        urls[name] = "http://localhost:{}".format(port)
    return urls


# ---------------------------------------------------------------------------
# "Why did this site fail?" - a quick network diagnosis run from THIS machine
# ---------------------------------------------------------------------------
# Firecrawl reports a site it cannot load as a generic error or a timeout, and
# a client that only sees that tends to wait and retry. Very often the real
# cause is local and stays until the network setup changes: the name resolves
# to an address nothing answers on - typically a proxy/VPN tool's fake-IP DNS
# handing out 198.18.0.0/15 while its tunnel is not carrying the traffic, so
# every packet is silently dropped. diagnose_url() resolves the host and makes
# one short TCP connection per address to say so plainly. It only runs AFTER a
# failure (never on the happy path), is bounded to a few seconds, and never
# raises.

_FAKE_IP_NET = ipaddress.ip_network("198.18.0.0/15")  # RFC 2544 benchmarking range
_SHARED_NET = ipaddress.ip_network("100.64.0.0/10")   # RFC 6598 CGNAT / VPN overlays

_KIND_TEXT = {
    "fake-ip": ("a fake-IP address (198.18.0.0/15 is reserved for benchmarking and is "
                "never routed on the internet; proxy/VPN tools such as Clash, Mihomo, "
                "Surge, sing-box or Shadowrocket hand these out in fake-IP DNS mode and "
                "relay the traffic themselves)"),
    "shared": ("a shared-address-space address (100.64.0.0/10: carrier-grade NAT or a "
               "VPN overlay such as Tailscale)"),
    "loopback": "a loopback address (this machine itself)",
    "link-local": "a link-local address",
    "private": "a private-network address",
    "reserved": "a reserved, non-public address",
}

# getaddrinfo error codes that mean "this name does not exist" (not a hiccup).
_NO_SUCH_NAME = set(c for c in (getattr(socket, "EAI_NONAME", None),
                                getattr(socket, "EAI_NODATA", None), 11001)
                    if c is not None)


def classify_ip(addr):
    """Kind of a NON-public address: 'fake-ip', 'shared', 'loopback',
    'link-local', 'private' or 'reserved'; None for an ordinary public one
    (or something that is not an IP address)."""
    try:
        ip = ipaddress.ip_address(str(addr).split("%", 1)[0])
    except ValueError:
        return None
    mapped = getattr(ip, "ipv4_mapped", None)
    if mapped is not None:
        ip = mapped
    if ip.version == 4 and ip in _FAKE_IP_NET:
        return "fake-ip"
    if ip.version == 4 and ip in _SHARED_NET:
        return "shared"
    if ip.is_loopback:
        return "loopback"
    if ip.is_link_local:
        return "link-local"
    if ip.is_private:
        return "private"
    if ip.is_unspecified or ip.is_multicast or ip.is_reserved or not ip.is_global:
        return "reserved"
    return None


def is_timeout(exc):
    """True when `exc` (or the reason wrapped inside a URLError) is a timeout."""
    if isinstance(exc, (socket.timeout, TimeoutError)):
        return True
    return isinstance(getattr(exc, "reason", None), (socket.timeout, TimeoutError))


def tcp_probe(addr, port, timeout=3.0):
    """One TCP connection attempt -> (state, seconds). state is 'open',
    'timeout' (packets dropped), 'refused', 'unreachable' or 'error'."""
    start = time.time()
    try:
        with socket.create_connection((addr, port), timeout=timeout):
            return "open", time.time() - start
    except (socket.timeout, TimeoutError):
        return "timeout", time.time() - start
    except ConnectionRefusedError:
        return "refused", time.time() - start
    except OSError as e:
        gone = (errno.ENETUNREACH, errno.EHOSTUNREACH)
        if getattr(e, "errno", None) in gone or getattr(e, "winerror", None) in (10051, 10065):
            return "unreachable", time.time() - start
        return "error", time.time() - start


def port_listening(endpoint, timeout=1.0):
    """True when something accepts TCP connections at an http(s) endpoint URL
    (used to tell 'the stack is down' from 'the stack is up but slow')."""
    try:
        parts = urlsplit(endpoint)
        host = parts.hostname or "localhost"
        port = parts.port or (443 if parts.scheme == "https" else 80)
    except ValueError:
        return False
    return tcp_probe(host, port, timeout)[0] == "open"


def _resolve(host, timeout):
    """Addresses the system resolver gives for `host` (deduplicated, in order).
    Raises socket.gaierror / TimeoutError (getaddrinfo itself has no timeout)."""
    box = {}

    def work():
        try:
            box["v"] = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
        except Exception as e:  # handed back to the caller below
            box["e"] = e

    t = threading.Thread(target=work, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        raise TimeoutError("DNS lookup timed out after {:g}s".format(timeout))
    if "e" in box:
        raise box["e"]
    addrs = []
    for info in box["v"]:
        a = info[4][0]
        if a not in addrs:
            addrs.append(a)
    return addrs


def _probe_all(addrs, port, timeout):
    """tcp_probe every address in parallel -> [(addr, state, seconds)]."""
    found = {}

    def work(a):
        found[a] = tcp_probe(a, port, timeout)

    threads = [threading.Thread(target=work, args=(a,), daemon=True) for a in addrs]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout + 1.0)
    return [(a,) + found.get(a, ("timeout", timeout)) for a in addrs]


class Diagnosis(object):
    """Outcome of diagnose_url().

    blocked   True when no connection to the site could be made from this
              machine right now - waiting and re-running the same request
              will not change that, so callers must not retry it.
    text      the printable multi-line explanation."""

    def __init__(self, host, blocked, lines):
        self.host = host
        self.blocked = blocked
        self.lines = lines

    @property
    def text(self):
        return "\n".join(self.lines)


def _describe_probe(addr, state, secs, timeout):
    if state == "open":
        return "{}: connected in {:.1f}s".format(addr, secs)
    if state == "timeout":
        return "{}: no answer within {:g}s (packets are being dropped)".format(addr, timeout)
    if state == "refused":
        return "{}: connection refused".format(addr)
    if state == "unreachable":
        return "{}: no route to host".format(addr)
    return "{}: connection failed".format(addr)


def _diagnose(url, connect_timeout, dns_timeout):
    parts = urlsplit(url if "://" in url else "https://" + url)
    host = parts.hostname
    if not host or parts.scheme not in ("http", "https"):
        return None
    if host.lower() == "localhost" or host.lower().endswith(".localhost"):
        return None
    try:
        port = parts.port or (80 if parts.scheme == "http" else 443)
    except ValueError:
        return None

    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        literal = None
    if literal is not None:
        if literal.is_loopback:
            return None
        addrs = [host]
    else:
        try:
            addrs = _resolve(host, dns_timeout)
        except socket.gaierror as e:
            gone = getattr(e, "errno", None) in _NO_SUCH_NAME
            lines = ["Network check for {} (from this machine): DNS lookup failed ({}).".format(host, e)]
            if gone:
                lines.append("The name does not exist or is being filtered, so this URL cannot be "
                             "loaded. Check the spelling of the address and any DNS filter / "
                             "VPN / hosts-file entry; waiting and retrying will not help.")
            else:
                lines.append("The DNS resolver gave a temporary failure; check this machine's "
                             "network / DNS settings.")
            return Diagnosis(host, gone, lines)
        except TimeoutError as e:
            return Diagnosis(host, False, [
                "Network check for {} (from this machine): {}. The DNS resolver is "
                "not answering; check this machine's network / DNS settings.".format(host, e)])
        if not addrs:
            return None

    kinds = [(a, classify_ip(a)) for a in addrs]
    probes = _probe_all(addrs[:4], port, connect_timeout)

    lines = ["Network check for {} (run from this machine, not from inside the container):".format(host)]
    if literal is None:
        lines.append("  DNS: {} -> {}".format(host, ", ".join(addrs[:4])))
    shown = set()
    for a, k in kinds:
        if k and k not in shown:
            shown.add(k)
            lines.append("  {} is {}.".format(a, _KIND_TEXT[k]))
    for a, state, secs in probes:
        lines.append("  TCP {}: {}".format(port, _describe_probe(a, state, secs, connect_timeout)))

    if any(state == "open" for _a, state, _s in probes):
        if any(k for _a, k in kinds):
            lines.append("A proxy/VPN is answering for this non-public address, so this machine's "
                         "path works. If the scrape still failed, the Firecrawl container probably "
                         "does not use the same path (its DNS, proxy or routing).")
        else:
            lines.append("The site accepts connections from this machine, so this is not a blocked "
                         "route: most likely the Firecrawl/browser container's own network (DNS, "
                         "proxy, routing) or the site refusing automated access (bot protection).")
        return Diagnosis(host, False, lines)

    kind_set = set(k for _a, k in kinds if k)
    states = set(state for _a, state, _s in probes)
    if "fake-ip" in kind_set:
        cause = ("Cause: DNS returned a fake-IP, but the proxy/VPN tool that owns it is not carrying "
                 "the traffic (tool stopped, its TUN / system-wide mode off, or a rule that drops "
                 "this site). Fix on the network side: start the tool and enable TUN mode, or add "
                 "this domain to its fake-ip-filter / a DIRECT rule, or turn fake-IP DNS off. "
                 "Docker/Podman containers need the same path.")
    elif kind_set:
        cause = ("Cause: the name resolves to a non-public address that nothing answers on "
                 "(a VPN, proxy, DNS filter or hosts-file entry). Check that configuration "
                 "for this domain.")
    elif "timeout" in states:
        cause = ("Cause: packets to the site are dropped before reaching it (firewall, VPN, "
                 "ISP/geo block) or the site is down.")
    elif "refused" in states:
        cause = "Cause: the server actively refuses connections on port {}.".format(port)
    else:
        cause = "Cause: there is no network route to the site from this machine."
    lines.append("Result: no connection to {}:{} can be made - the route is blocked at the network "
                 "level; this is not a temporary site error.".format(host, port))
    lines.append(cause)
    lines.append("Waiting and re-running this same request will not help: do not retry this URL. "
                 "Use a different source for the information (another URL, e.g. from a fresh "
                 "web_search) and tell the user about the network problem.")
    return Diagnosis(host, True, lines)


def diagnose_url(url, connect_timeout=3.0, dns_timeout=5.0):
    """Explain, from this machine, why `url` could not be loaded: resolve the
    host and try one TCP connection per address (parallel, `connect_timeout`
    seconds at most). Returns a Diagnosis, or None when nothing useful can be
    said (not an http(s) URL, localhost, unexpected error). Never raises."""
    try:
        return _diagnose(str(url).strip(), connect_timeout, dns_timeout)
    except Exception:
        return None
