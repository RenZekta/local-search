#!/usr/bin/env python3
"""Ensure the local-search stack is running before any web research.

Two ways to use it:

  1. As a CLI pre-flight check (OPTIONAL — the other scripts self-heal):
         python ensure_stack.py [--check]
     Exit codes: 0 ready, 1 down / could not be brought up, 2 prerequisites
     missing (no install folder, no Podman/Docker, no compose).

  2. As a module (used by web_search.py / web_scrape.py for self-healing):
         import ensure_stack
         ok, message, code = ensure_stack.ensure_ready()
     When a search/scrape request fails with a connection error, those
     scripts call ensure_ready() automatically, then retry the request
     once — so the agent can call them directly with no warm-up step.

Behaviour (both CLI and module):
  * Both endpoints answering -> return immediately (fast path, < 1 s).
  * Otherwise: make sure the container engine is running (if it is down, launch
    Docker Desktop / the docker service / the Podman machine and wait for it),
    then start the containers with `podman compose up -d` / `docker compose
    up -d` in the install folder (the same command Run.bat / run.sh run,
    without the interactive `pause`) and wait until both endpoints answer.
    The engine is Podman when it is installed (it wins when both are), else
    Docker - override with LOCAL_SEARCH_ENGINE=podman|docker, or the same line
    in the install folder's .env (the installer records its choice there).
    The stack is NEVER stopped by this script.

The readiness timeout defaults to 240 s and can be overridden with the
LOCAL_SEARCH_READY_TIMEOUT env var (seconds) — used by the test suite to
exercise the failure path quickly.

The install folder (holds docker-compose.yml) is found by config.py, in order:
    1. the LOCAL_SEARCH_DIR env var (explicit override),
    2. the compose label on the containers — compose tags each container with
       the directory it was started from (engine must be up),
    3. install-dir.txt — the path recorded by the local-search installer
       when it copied this skill,
    4. ~/local-search.
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so status/progress messages never crash with a
# UnicodeEncodeError. Skipped if PYTHONIOENCODING is already set — an
# explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

READY_TIMEOUT = int(os.environ.get("LOCAL_SEARCH_READY_TIMEOUT", "240") or 240)
POLL_EVERY = 3
DISPLAY = {"searxng": "SearXNG", "firecrawl": "Firecrawl"}


def endpoint_up(url, timeout=4):
    """True if the endpoint accepts connections (any HTTP status counts)."""
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=timeout):
            return True
    except urllib.error.HTTPError:
        return True  # got an HTTP response (even 4xx/5xx) = service is up
    except Exception:
        return False  # connection refused / reset / timeout = down


def port_of(url):
    return url.rsplit(":", 1)[1]


def status(endpoints):
    return {name: endpoint_up(url) for name, url in endpoints.items()}


def ready_message(endpoints):
    return "Stack is ready (SearXNG :{0}, Firecrawl :{1}).".format(
        port_of(endpoints["searxng"]), port_of(endpoints["firecrawl"]))


def _ok(cmd):
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except (OSError, FileNotFoundError):
        return False


def compose_command(engine="docker"):
    if engine == "podman":
        if shutil.which("podman") and _ok(["podman", "compose", "version"]):
            return ["podman", "compose"]
        if shutil.which("podman-compose"):
            return ["podman-compose"]
        return None
    if shutil.which("docker") and _ok(["docker", "compose", "version"]):
        return ["docker", "compose"]
    if shutil.which("docker-compose"):
        return ["docker-compose"]
    return None


def engine_up(engine):
    return _ok([engine, "info"])


def ensure_podman_socket():
    """`podman compose` normally hands over to docker-compose, which talks to
    Podman's API socket; on a fresh Fedora session that socket is not running.
    Best effort, Linux only, never fatal. True when the socket exists."""
    import platform
    if platform.system() != "Linux":
        return True

    def exists():
        try:
            out = subprocess.run(
                ["podman", "info", "--format", "{{.Host.RemoteSocket.Exists}}"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            return out.stdout.strip() == "true"
        except (OSError, FileNotFoundError):
            return False

    if exists():
        return True
    if shutil.which("systemctl"):
        rootless = subprocess.run(
            ["podman", "info", "--format", "{{.Host.Security.Rootless}}"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
        ).stdout.strip() == "true"
        if rootless:
            _ok(["systemctl", "--user", "start", "podman.socket"])
        elif not _ok(["systemctl", "start", "podman.socket"]) and shutil.which("sudo"):
            _ok(["sudo", "-n", "systemctl", "start", "podman.socket"])
    return exists()


def find_docker_desktop_exe():
    candidates = [
        r"C:\Program Files\Docker\Docker\Docker Desktop.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\Docker Desktop\Docker Desktop.exe"),
    ]
    for p in candidates:
        if os.path.isfile(p):
            return p
    return None


def start_engine(engine):
    """Try to launch the container engine for this OS. True if the launch was
    initiated (not that it became ready — that's wait_for_engine's job)."""
    import platform
    system = platform.system()
    if engine == "podman":
        # Linux: rootless Podman has no daemon - nothing to start. macOS /
        # Windows: Podman runs in a VM ("podman machine") that must be started.
        if system == "Linux":
            return False
        try:
            names = subprocess.run(
                ["podman", "machine", "list", "--format", "{{.Name}}"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            if not names.stdout.strip():
                return False
            subprocess.Popen(["podman", "machine", "start"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except OSError:
            return False
    if system == "Windows":
        exe = find_docker_desktop_exe()
        if not exe:
            return False
        try:
            subprocess.Popen([exe],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except OSError:
            return False
    if system == "Darwin":
        try:
            subprocess.Popen(["open", "--background", "-a", "Docker"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except OSError:
            return False
    # Linux: best effort without an interactive password prompt.
    try:
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            return subprocess.run(["systemctl", "start", "docker"],
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL).returncode == 0
        return subprocess.run(["sudo", "-n", "systemctl", "start", "docker"],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except (OSError, FileNotFoundError):
        return False


def wait_for_engine(engine, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if engine_up(engine):
            return True
        time.sleep(3)
    return False


def ensure_ready(check_only=False, ready_timeout=None, poll_every=None):
    """Bring the local-search stack to a ready state. NEVER stops it.

    Returns (ok, message, exit_code):
        ok         True when both endpoints answer.
        message    human-readable status / guidance (progress is printed to
                   stderr along the way).
        exit_code  0 ready, 1 down/could not bring up, 2 prerequisites
                   missing (matches the CLI exit codes).
    """
    if ready_timeout is None:
        ready_timeout = READY_TIMEOUT
    if poll_every is None:
        poll_every = POLL_EVERY

    endpoints = config.endpoints(config.find_install_dir())
    st = status(endpoints)
    if all(st.values()):
        return True, ready_message(endpoints), 0

    print("Local-search stack is DOWN:", file=sys.stderr)
    for name, url in endpoints.items():
        mark = "OK  " if st[name] else "DOWN"
        print(f"  [{mark}] {DISPLAY[name]} :{port_of(url)}", file=sys.stderr)
    if check_only:
        return False, "Stack is down (--check: nothing was started).", 1

    engine, auto = config.engine_choice(config.find_install_dir())
    if engine is None:
        return False, ("No container engine found: neither Podman nor Docker is "
                       "on PATH (or LOCAL_SEARCH_ENGINE names one that is not "
                       "installed). Install one, then re-run this script."), 2
    name = engine.capitalize()

    if not engine_up(engine):
        print(f"{name} engine is not running — trying to start it ...",
              file=sys.stderr)
        if start_engine(engine):
            print(f"Waiting for the {name} engine to come up ...", file=sys.stderr)
            if not wait_for_engine(engine, timeout=180):
                return False, (f"The {name} engine was launched but did not answer "
                               f"within 180 s. Check {name}, then re-run this script."), 2
        elif auto and engine == "podman" and shutil.which("docker") and engine_up("docker"):
            print("Podman is not responding — using Docker instead.", file=sys.stderr)
            engine, name = "docker", "Docker"
        else:
            return False, (f"Could not start the {name} engine automatically "
                           "(Docker Desktop not found in the usual locations? "
                           "Is rootless Podman set up — does 'podman info' work?). "
                           "Start it manually, then re-run this script."), 2

    # Recomputed now that the engine is up: the compose-label lookup (which
    # needs the engine) can find the install dir where the other methods
    # could not.
    install_dir = config.find_install_dir()
    if not install_dir:
        return False, ("Could not find the local-search install folder "
                       "(no docker-compose.yml found). Ask the user where their "
                       "local-search folder is, then re-run this script with "
                       "LOCAL_SEARCH_DIR set to that path, or start the stack manually "
                       "(Run.bat / run.sh)."), 2

    compose = compose_command(engine)
    if not compose:
        if engine == "podman":
            return False, ("No compose provider for Podman: install 'docker-compose' "
                           "(Compose v2) or 'podman-compose'."), 2
        return False, "Neither 'docker compose' nor 'docker-compose' is available.", 2
    compose_label = " ".join(compose)

    env = dict(os.environ)
    if engine == "podman":
        env["PODMAN_COMPOSE_WARNING_LOGS"] = "false"
        if compose == ["podman", "compose"] and not ensure_podman_socket():
            print("Podman's API socket is not active; if compose fails, run: "
                  "systemctl --user enable --now podman.socket", file=sys.stderr)

    print(f"Starting stack in {install_dir} ({compose_label}) ...", file=sys.stderr)
    proc = subprocess.run(compose + ["up", "-d"], cwd=install_dir, env=env)
    if proc.returncode != 0:
        return False, f"'{compose_label} up -d' failed — see output above.", 1

    print("Waiting for endpoints ...", file=sys.stderr)
    deadline = time.time() + ready_timeout
    while time.time() < deadline:
        st = status(endpoints)
        if all(st.values()):
            return True, ready_message(endpoints), 0
        time.sleep(poll_every)

    for name, url in endpoints.items():
        mark = "OK  " if st[name] else "DOWN"
        print(f"  [{mark}] {DISPLAY[name]} :{port_of(url)}", file=sys.stderr)
    return False, (f"Stack did not become ready within {ready_timeout}s. Inspect with:\n"
                   f"    cd {install_dir} && {compose_label} logs --tail 50"), 1


def main():
    ap = argparse.ArgumentParser(description="Ensure the local-search container stack is running.")
    ap.add_argument("--check", action="store_true",
                    help="only report status; never start anything")
    args = ap.parse_args()

    ok, message, code = ensure_ready(check_only=args.check)
    if ok:
        print(message)
        return 0
    print(message, file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
