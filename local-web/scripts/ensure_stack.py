#!/usr/bin/env python3
"""Ensure the local-search stack is running before any web research.

Two ways to use it:

  1. As a CLI pre-flight check (OPTIONAL — the other scripts self-heal):
         python ensure_stack.py [--check]
     Exit codes: 0 ready, 1 down / could not be brought up, 2 prerequisites
     missing (no install folder, no Docker, no compose).

  2. As a module (used by web_search.py / web_scrape.py for self-healing):
         import ensure_stack
         ok, message, code = ensure_stack.ensure_ready()
     When a search/scrape request fails with a connection error, those
     scripts call ensure_ready() automatically, then retry the request
     once — so the agent can call them directly with no warm-up step.

Behaviour (both CLI and module):
  * Both endpoints answering -> return immediately (fast path, < 1 s).
  * Otherwise: make sure the Docker engine is running (if it is down, launch
    Docker Desktop / the docker service and wait for the daemon), then start
    the containers with `docker compose up -d` in the install folder (the
    same command Run.bat / run.sh run, without the interactive `pause`) and
    wait until both endpoints answer again.
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

READY_TIMEOUT = int(os.environ.get("LOCAL_SEARCH_READY_TIMEOUT", "240") or 240)
POLL_EVERY = 3
DISPLAY = {"searxng": "SearXNG", "firecrawl": "Firecrawl"}


def endpoint_up(url, timeout=4):
    """True if the endpoint accepts connections (any HTTP status counts)."""
    req = urllib.request.Request(url, headers={"User-Agent": "zcode-local-web/1.0"})
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


def compose_command():
    if shutil.which("docker"):
        rc = subprocess.run(
            ["docker", "compose", "version"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        if rc.returncode == 0:
            return ["docker", "compose"]
    if shutil.which("docker-compose"):
        return ["docker-compose"]
    return None


def docker_engine_up():
    try:
        return subprocess.run(
            ["docker", "info"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ).returncode == 0
    except (OSError, FileNotFoundError):
        return False


def find_docker_desktop_exe():
    candidates = [
        r"C:\Program Files\Docker\Docker\Docker Desktop.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\Docker Desktop\Docker Desktop.exe"),
    ]
    for p in candidates:
        if os.path.isfile(p):
            return p
    return None


def start_docker_engine():
    """Try to launch the Docker engine for this OS. True if the launch was
    initiated (not that it became ready — that's wait_for_engine's job)."""
    import platform
    system = platform.system()
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


def wait_for_engine(timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if docker_engine_up():
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

    if not docker_engine_up():
        print("Docker engine is not running — trying to start it ...",
              file=sys.stderr)
        if not start_docker_engine():
            return False, ("Could not start the Docker engine automatically "
                           "(Docker Desktop not found in the usual locations?). "
                           "Start it manually, then re-run this script."), 2
        print("Waiting for the Docker engine to come up ...", file=sys.stderr)
        if not wait_for_engine(timeout=180):
            return False, ("The Docker engine was launched but did not answer within "
                           "180 s. Check Docker Desktop, then re-run this script."), 2

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

    compose = compose_command()
    if not compose:
        return False, "Neither 'docker compose' nor 'docker-compose' is available.", 2

    print(f"Starting stack in {install_dir} ...", file=sys.stderr)
    proc = subprocess.run(compose + ["up", "-d"], cwd=install_dir)
    if proc.returncode != 0:
        return False, "'docker compose up -d' failed — see output above.", 1

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
                   f"    cd {install_dir} && docker compose logs --tail 50"), 1


def main():
    ap = argparse.ArgumentParser(description="Ensure the local-search Docker stack is running.")
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
