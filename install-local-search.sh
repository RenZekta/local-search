#!/usr/bin/env bash
# =============================================================================
#  Local Search Installer  (Firecrawl + SearXNG + local-web-search skill)
#                        -  Linux & macOS
# =============================================================================
#  Self-contained: every file the installer needs is embedded below as a
#  quoted heredoc. If a source file is missing from this script's folder
#  (e.g. you only downloaded this one .sh), the embedded copy is used.
#  After installing the stack it also copies the bundled local-web-search agent
#  skill into ~/.agents/skills/local-web-search.
#  It also asks which browser rendering engine Firecrawl should use -
#  Playwright (default) or Browserless (stealth mode, better block
#  avoidance) - and writes COMPOSE_PROFILES so only that one starts.
#  The installer asks a y/N "Add a Firecrawl account?" question (default N):
#  without an account only the free local skill tools are installed (the
#  19 account-gated scripts are skipped and a core-only SKILL.md is used);
#  with one the credentials are written to .env and all 25 tools install (26 with an LLM).
#  Container engine: Podman is used when it is installed (it wins when both
#  are present), otherwise Docker. Override with LOCAL_SEARCH_ENGINE=podman|
#  docker. The detection logic is engine.sh, inlined below. On SELinux hosts
#  (Fedora/RHEL) and rootless Podman it also tunes how SearXNG's config folder
#  is mounted (SEARXNG_MOUNT_OPTS / SEARXNG_FORCE_OWNERSHIP in .env).
#  If the engine is not running, the installer tries to start it
#  automatically (Docker Desktop / Podman machine on macOS, systemctl/service
#  on Linux) and waits for it before pulling images. After starting the stack
#  it checks that SearXNG really answers and diagnoses it when it does not.
# =============================================================================

set -u

BOLD="\033[1m"; DIM="\033[2m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
say()  { printf "%b\n" "$1"; }
err()  { printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$1" >&2; }
ok()   { printf "%b[OK]%b %s\n" "$GREEN" "$RESET" "$1"; }
hdr()  { printf "\n%b--- %s ---%b\n" "$CYAN" "$1" "$RESET"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }  # bash-3.2 (macOS) safe

cat <<'BANNER'
============================================================
  Local Search Installer  (Firecrawl + SearXNG + local-web-search)
  A local web-browsing system for AI models.
============================================================
BANNER

# ---- engine.sh (inlined verbatim by gen_installers.py) ---------------------
# =============================================================================
#  engine.sh - container-engine detection for the Local Search shell scripts
# =============================================================================
#  Sourced by run.sh / stop.sh / update.sh / uninstall.sh, and inlined verbatim
#  into install-local-search.sh by gen_installers.py - so there is exactly ONE
#  copy of this logic. It is a library: it is not meant to be run on its own.
#
#  Which engine is used (first match wins):
#    1. LOCAL_SEARCH_ENGINE=podman|docker in the environment   (forced)
#    2. LOCAL_SEARCH_ENGINE=podman|docker in the install folder's .env
#       (the installer records its choice there, so run.sh / update.sh keep
#        using the engine that created the containers)
#    3. auto-detect: Podman when it is installed, otherwise Docker
#       (if both are installed, Podman wins)
#
#  Functions (all bash 3.2 safe):
#    ls_select_engine [ENVFILE]  sets ENGINE (podman|docker), ENGINE_NAME, ENGINE_AUTO
#    ls_engine_running           0 when the selected engine answers
#    ls_start_engine             best-effort launch of a stopped engine
#    ls_fallback_engine          auto-picked Podman unusable + Docker running -> Docker
#    ls_engine_hint              prints "how to start it yourself" help
#    ls_select_compose           sets DC (e.g. "podman compose", "docker compose")
#    ls_ensure_podman_socket     starts Podman's API socket (needed by docker-compose)
#    ls_platform_env             sets LS_MOUNT_OPTS / LS_FORCE_OWNERSHIP for .env
#    ls_verify_searxng PORT      waits until SearXNG answers; diagnoses if it does not
#    ls_fix_container_proxy PORT  blanks loopback proxy variables the containers inherited from the shell
#    ls_pause_on_exit            keeps a launcher-opened terminal window open at the end
#    ls_require_engine [running] select + compose (+ running check); exits on failure
# =============================================================================

ls_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
ls_err()   { if type err >/dev/null 2>&1; then err "$1"; else printf '[ERROR] %s\n' "$1" >&2; fi; }
ls_say()   { if type say >/dev/null 2>&1; then say "$1"; else printf '%s\n' "$1"; fi; }
ls_ok()    { if type ok  >/dev/null 2>&1; then ok  "$1"; else printf '[OK] %s\n' "$1"; fi; }

# ls_env_value FILE KEY -> the last KEY=value line of FILE (quotes / CR stripped)
ls_env_value() {
  [ -f "$1" ] || return 0
  grep -E "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r"' | tr -d "'"
}

ls_install_hint() {
  ls_say ""
  ls_say "Install one of them, then re-run:"
  ls_say "  Podman (preferred when both are installed):"
  ls_say "    Fedora / RHEL:    sudo dnf install podman docker-compose"
  ls_say "    Debian / Ubuntu:  sudo apt install podman docker-compose-v2"
  ls_say "    macOS:            brew install podman docker-compose && podman machine init"
  ls_say "  Docker:"
  ls_say "    Linux:  https://docs.docker.com/engine/install/"
  ls_say "    macOS:  https://www.docker.com/products/docker-desktop/"
}

ls_select_engine() {
  local want="" src="" have_p=0 have_d=0
  ENGINE=""; ENGINE_NAME=""; ENGINE_AUTO=0
  command -v podman >/dev/null 2>&1 && have_p=1
  command -v docker >/dev/null 2>&1 && have_d=1

  want="$(ls_lower "${LOCAL_SEARCH_ENGINE:-}")"
  if [ -n "$want" ]; then
    src="LOCAL_SEARCH_ENGINE"
  elif [ -n "${1:-}" ]; then
    want="$(ls_lower "$(ls_env_value "$1" LOCAL_SEARCH_ENGINE)")"
    src=".env"
  fi
  case "$want" in
    ""|auto) want="" ;;
    podman|docker) ;;
    *) ls_err "$src must be 'podman' or 'docker' (got '$want')."; return 1 ;;
  esac

  if [ -n "$want" ]; then
    if [ "$want" = "podman" ] && [ "$have_p" = 1 ]; then ENGINE=podman; ENGINE_NAME=Podman; return 0; fi
    if [ "$want" = "docker" ] && [ "$have_d" = 1 ]; then ENGINE=docker; ENGINE_NAME=Docker; return 0; fi
    if [ "$src" = "LOCAL_SEARCH_ENGINE" ]; then
      ls_err "LOCAL_SEARCH_ENGINE=$want, but '$want' was not found on your PATH."
      return 1
    fi
    ls_say "  [!] .env asks for '$want', which is not installed - auto-detecting instead."
  fi

  ENGINE_AUTO=1
  if   [ "$have_p" = 1 ]; then ENGINE=podman; ENGINE_NAME=Podman
  elif [ "$have_d" = 1 ]; then ENGINE=docker; ENGINE_NAME=Docker
  else
    ls_err "Neither Podman nor Docker was found on your PATH."
    ls_install_hint
    return 1
  fi
  return 0
}

ls_engine_running() { "$ENGINE" info >/dev/null 2>&1; }

# Auto-picked Podman cannot run but Docker answers: use Docker (with a notice
# from the caller). Never overrides an explicit LOCAL_SEARCH_ENGINE / .env choice.
ls_fallback_engine() {
  [ "${ENGINE_AUTO:-0}" = 1 ] && [ "$ENGINE" = "podman" ] || return 1
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
  ENGINE=docker; ENGINE_NAME=Docker
  return 0
}

# Launch a stopped engine. Returns 0 when a start was issued (the caller waits
# for it with ls_engine_running), 1 when there is nothing it can start.
ls_start_engine() {
  local unit
  if [ "$ENGINE" = "podman" ]; then
    # Linux: rootless Podman has no daemon, so there is nothing to start.
    # macOS: Podman runs in a VM ("podman machine") that has to be started.
    if [ "$(uname)" = "Darwin" ]; then
      [ -n "$(podman machine list --format '{{.Name}}' 2>/dev/null)" ] || return 1
      ( podman machine start >/dev/null 2>&1 & )
      return 0
    fi
    return 1
  fi
  if [ "$(uname)" = "Darwin" ]; then
    # macOS: launch Docker Desktop if it is installed
    if command -v open >/dev/null 2>&1 \
       && { [ -d "/Applications/Docker.app" ] || [ -d "$HOME/Applications/Docker.app" ]; }; then
      open -a Docker >/dev/null 2>&1 && return 0
    fi
    return 1
  fi
  # Linux: systemd units (Docker Desktop uses docker-desktop, the classic
  # engine uses docker), then service(1). Non-interactive sudo only - an
  # installer never prompts for a password.
  if command -v systemctl >/dev/null 2>&1; then
    for unit in docker-desktop docker; do
      if systemctl start "$unit" >/dev/null 2>&1; then return 0; fi
      if command -v sudo >/dev/null 2>&1 \
         && sudo -n systemctl start "$unit" >/dev/null 2>&1; then
        return 0
      fi
    done
  fi
  if command -v service >/dev/null 2>&1; then
    if service docker start >/dev/null 2>&1; then return 0
    elif command -v sudo >/dev/null 2>&1 \
         && sudo -n service docker start >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

ls_engine_hint() {
  if [ "$ENGINE" = "podman" ]; then
    ls_say "  Run 'podman info' to see why Podman does not answer."
    ls_say "  (rootless Podman needs a normal login session and subuid/subgid entries)"
    ls_say "  macOS:  podman machine init && podman machine start"
  else
    ls_say "  Linux:  sudo systemctl start docker    (or launch Docker Desktop)"
    ls_say "          permission denied from docker? add yourself to the docker"
    ls_say "          group:  sudo usermod -aG docker ${USER:-youruser}  (log out and back in)"
    ls_say "  macOS:  open -a Docker"
  fi
}

ls_select_compose() {
  DC=""
  if [ "$ENGINE" = "podman" ]; then
    if podman compose version >/dev/null 2>&1; then DC="podman compose"
    elif command -v podman-compose >/dev/null 2>&1; then DC="podman-compose"
    else
      ls_err "No compose provider was found for Podman."
      ls_say "  Install one (Compose v2 'docker-compose' is the most compatible):"
      ls_say "    Fedora / RHEL:    sudo dnf install docker-compose     (or: podman-compose)"
      ls_say "    Debian / Ubuntu:  sudo apt install docker-compose-v2  (or: podman-compose)"
      ls_say "    macOS:            brew install docker-compose"
      return 1
    fi
    # 'podman compose' prints a provider banner on every call in newer Podman.
    export PODMAN_COMPOSE_WARNING_LOGS=false
  else
    if docker compose version >/dev/null 2>&1; then DC="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
    else
      ls_err "Docker Compose was not found. Install the 'docker compose' plugin (v2)."
      return 1
    fi
  fi
  return 0
}

# 'podman compose' normally hands over to docker-compose, which talks to
# Podman's API socket. On a fresh Fedora session that socket is not running, and
# docker-compose then fails with "Cannot connect to the Docker daemon". Start it
# when possible. Returns 0 when the socket exists afterwards. Never fatal: a
# compose provider that does not need the socket (podman-compose) works anyway.
ls_ensure_podman_socket() {
  [ "$ENGINE" = "podman" ] && [ "$DC" = "podman compose" ] || return 0
  [ "$(uname)" = "Linux" ] || return 0
  [ "$(podman info --format '{{.Host.RemoteSocket.Exists}}' 2>/dev/null)" = "true" ] && return 0
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
      systemctl --user start podman.socket >/dev/null 2>&1
    else
      systemctl start podman.socket >/dev/null 2>&1 \
        || { command -v sudo >/dev/null 2>&1 && sudo -n systemctl start podman.socket >/dev/null 2>&1; }
    fi
  fi
  [ "$(podman info --format '{{.Host.RemoteSocket.Exists}}' 2>/dev/null)" = "true" ]
}

ls_selinux_on() {
  [ "$(uname)" = "Linux" ] || return 1
  if command -v getenforce >/dev/null 2>&1; then
    case "$(getenforce 2>/dev/null)" in Enforcing|Permissive) return 0 ;; esac
    return 1
  fi
  [ -e /sys/fs/selinux/enforce ]
}

ls_podman_rootless() {
  [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]
}

# Decides the two SearXNG bind-mount settings that the installer writes to .env
# (they feed ${SEARXNG_MOUNT_OPTS} / ${SEARXNG_FORCE_OWNERSHIP} in the compose file):
#   LS_MOUNT_OPTS       ",z" on SELinux hosts (lets the container read the folder)
#   LS_FORCE_OWNERSHIP  "false" on rootless Podman (keeps the files yours), else "true"
ls_platform_env() {
  LS_MOUNT_OPTS=""; LS_FORCE_OWNERSHIP="true"
  if ls_selinux_on; then LS_MOUNT_OPTS=",z"; fi
  if [ "$ENGINE" = "podman" ] && ls_podman_rootless; then LS_FORCE_OWNERSHIP="false"; fi
  return 0
}

# ls_http_ok PORT -> 0 when something answers HTTP on localhost:PORT. A bare TCP
# connect is not enough: the engine publishes the port even while the container
# behind it is crash-looping.
ls_http_ok() {
  (
    exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
    printf 'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
    line=""
    IFS= read -r -t 3 line <&3 || exit 1
    case "$line" in HTTP/*) exit 0 ;; esac
    exit 1
  ) 2>/dev/null
}

# ls_verify_searxng PORT  (run from the install folder; needs $DC)
# Waits up to LOCAL_SEARCH_VERIFY_TIMEOUT seconds (default 90, 0 = skip). When
# SearXNG never answers it prints the container state + last log lines and, for
# permission errors, the SELinux fix. Returns 1 in that case.
ls_verify_searxng() {
  local port="$1" limit="${LOCAL_SEARCH_VERIFY_TIMEOUT:-90}" waited=0 logs=""
  [ "$limit" -gt 0 ] 2>/dev/null || return 0
  ls_say "Checking that SearXNG answers on port $port (up to ${limit}s)..."
  while :; do
    if ls_http_ok "$port"; then ls_ok "SearXNG is answering on port $port."; return 0; fi
    [ "$waited" -ge "$limit" ] && break
    sleep 3
    waited=$((waited + 3))
  done
  ls_err "SearXNG did not answer on port $port within ${limit}s."
  ls_say ""
  ls_say "  Container state:"
  $DC ps 2>&1 | sed 's/^/    /' | head -n 12
  logs="$($DC logs --tail 15 searxng 2>&1)"
  ls_say "  Last SearXNG log lines:"
  printf '%s\n' "$logs" | sed 's/^/    /'
  if printf '%s' "$logs" | grep -qi "permission denied"; then
    ls_say ""
    ls_say "  This is a bind-mount permission problem (typical on Fedora / RHEL with"
    ls_say "  SELinux). The compose file labels the SearXNG config folder through"
    ls_say "  SEARXNG_MOUNT_OPTS in .env, which should read:  SEARXNG_MOUNT_OPTS=,z"
    ls_say "  Check:  grep SEARXNG .env ; getenforce"
    ls_say "  Then restart with ./run.sh (or re-run the installer)."
  fi
  return 1
}

# ---- keep the window open --------------------------------------------------------
# A terminal opened by a file manager / launcher closes the moment the script ends,
# taking all output with it. When no interactive shell started us, wait for a key press
# before exiting (Run.bat / Install.bat do the same with `pause`).
#   LOCAL_SEARCH_PAUSE=0    never wait      LOCAL_SEARCH_PAUSE=1   always wait (on a terminal)
ls_launched_from_shell() {   # 0 = an interactive shell started us (the terminal stays open)
  local pid="${PPID:-0}" comm="" args="" hops=0
  command -v ps >/dev/null 2>&1 || return 1
  while [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 8 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"; comm="${comm##*/}"; comm="${comm#-}"
    args="$(ps -o args= -p "$pid" 2>/dev/null)"
    case "$comm" in
      bash|zsh|sh|dash|fish|ksh|mksh|ash|tcsh|csh|nu|elvish|xonsh)
        # `sh -c "./script"` is just a launcher's wrapper - look through it
        case " $args " in *" -c "*) ;; *) return 0 ;; esac ;;
      sudo|doas|env|time|timeout|nice|setsid|stdbuf|script|pkexec|su|nohup) ;;
      *) return 1 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"; hops=$((hops + 1))
  done
  return 1
}

ls_pause_now() {
  printf '\n'
  printf 'Press any key to close this window... '
  read -n 1 -s _ls_x </dev/tty 2>/dev/null || read -n 1 -s _ls_x 2>/dev/null || sleep 30
}

ls_pause_on_exit() {
  case "$(ls_lower "${LOCAL_SEARCH_PAUSE:-auto}")" in
    0|no|false|never) return 0 ;;
    1|yes|true|always) ;;
    *) ls_launched_from_shell && return 0 ;;
  esac
  { [ -t 0 ] && [ -t 1 ]; } || return 0
  # shellcheck disable=SC2154
  trap '_ls_rc=$?; ls_pause_now; exit $_ls_rc' EXIT
}

# ---- inherited proxy variables ----------------------------------------------------
# Podman copies the host shell's http_proxy / https_proxy / ... into every container
# (Docker does not). A loopback value such as http://127.0.0.1:7890 points at the
# container itself there, so every outgoing request fails at once ("Failed to connect over
# proxy 127.0.0.1 after 0 ms") although every container shows "Up". What the containers
# actually received is inspected, and exactly those loopback variables are blanked through a
# generated docker-compose.override.yml (docker compose and podman-compose load it
# automatically). Proxies that point at a real host (corporate, LAN) are left alone.
LS_OVERRIDE="docker-compose.override.yml"
LS_OVERRIDE_MARK="# local-search: generated container-network workaround"
LS_OVR_PROXY=""      # space separated (lowercase) proxy variable names blanked by the override

ls_override_is_ours() { [ -f "$LS_OVERRIDE" ] && head -n 1 "$LS_OVERRIDE" 2>/dev/null | grep -q "^# local-search: generated container-"; }

# Restore the variable list from an override this tool wrote earlier.
ls_override_load() {
  LS_OVR_PROXY=""
  ls_override_is_ours || return 0
  LS_OVR_PROXY="$(sed -n 's/^# ls-proxy-vars: *//p' "$LS_OVERRIDE" | head -n 1 | tr 'A-Z ' 'a-z\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//')"
}

# Writes the override from LS_OVR_PROXY; removes it when the list is empty.
ls_override_write() {
  local svc v uc
  if [ -z "$LS_OVR_PROXY" ]; then rm -f "$LS_OVERRIDE"; return 0; fi
  {
    echo "$LS_OVERRIDE_MARK (safe to delete - the installer rewrites it)"
    echo "# ls-proxy-vars: $LS_OVR_PROXY"
    echo "# Proxy variables copied from the host shell point at 127.0.0.1, which inside a container is"
    echo "# the container itself: blanked for every service that needs the internet."
    echo "services:"
    for svc in searxng firecrawl playwright-service browserless; do
      echo "  $svc:"
      echo "    environment:"
      for v in $LS_OVR_PROXY; do
        uc="$(printf '%s' "$v" | tr '[:lower:]' '[:upper:]')"
        echo "      - \"$v=\""
        echo "      - \"$uc=\""
      done
    done
  } > "$LS_OVERRIDE"
}

# Prints "NAME=value" for every proxy variable inside the SearXNG container that points at
# this very container (localhost / 127.x / ::1), one per line. Nothing when all is well.
ls_container_loopback_proxies() {
  local envtxt line name val host
  envtxt="$("$ENGINE" exec local-search-searxng env 2>/dev/null)" || return 0
  while IFS= read -r line; do
    name="${line%%=*}"; val="${line#*=}"
    case "$(ls_lower "$name")" in http_proxy|https_proxy|all_proxy|ftp_proxy) ;; *) continue ;; esac
    [ -n "$val" ] || continue
    host="${val#*://}"; host="${host##*@}"
    case "$host" in
      \[*) host="${host#\[}"; host="${host%%\]*}" ;;
      *)   host="${host%%[:/]*}" ;;
    esac
    case "$host" in localhost|127.*|::1|0.0.0.0) printf '%s=%s\n' "$name" "$val" ;; esac
  done <<EOF
$envtxt
EOF
}

ls_wait_http() {   # ls_wait_http PORT SECONDS
  local waited=0
  while ! ls_http_ok "$1"; do
    [ "$waited" -ge "$2" ] && return 1
    sleep 2; waited=$((waited + 2))
  done
}

# ls_fix_container_proxy PORT  (run from the install folder; needs $DC and the stack up)
ls_fix_container_proxy() {
  local port="$1" bad names v out
  [ "${LOCAL_SEARCH_VERIFY_TIMEOUT:-90}" -gt 0 ] 2>/dev/null || return 0
  ls_say "Checking the containers' proxy settings..."
  bad="$(ls_container_loopback_proxies)"
  if [ -z "$bad" ]; then ls_ok "The containers' proxy settings are fine."; return 0; fi

  ls_err "The containers inherited a proxy setting that cannot work from inside a container:"
  printf '%s\n' "$bad" | sed 's/^/      /'
  ls_say "  (Podman copies your shell's proxy variables into every container; 127.0.0.1 there is"
  ls_say "   the container itself, so every outgoing request fails at once - searches stay empty.)"
  if [ -f "$LS_OVERRIDE" ] && ! ls_override_is_ours; then
    ls_say "  $LS_OVERRIDE exists and is not ours, so I will not change it. Add to the 'environment:' of"
    ls_say "  searxng, firecrawl, playwright-service and browserless, set to empty:"
    ls_say "    http_proxy=   https_proxy=   all_proxy=   (and the UPPERCASE twins)"
    return 1
  fi
  ls_override_load
  names=""
  while IFS= read -r v; do [ -n "$v" ] && names="$names $(ls_lower "${v%%=*}")"; done <<EOF
$bad
EOF
  # shellcheck disable=SC2086
  LS_OVR_PROXY="$(printf '%s\n' $LS_OVR_PROXY $names | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  ls_say "  -> removing those variables inside the containers (written to $LS_OVERRIDE)..."
  ls_override_write
  if ! out="$($DC up -d 2>&1)"; then
    ls_say "  [!] '$DC up -d' failed while applying it:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/      /'
    return 1
  fi
  ls_wait_http "$port" 60 || true
  if [ -n "$(ls_container_loopback_proxies)" ]; then
    ls_err "The containers still carry a loopback proxy. Unset it in your shell and run ./run.sh:"
    ls_say "    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
    return 1
  fi
  ls_ok "The inherited loopback proxy is gone from the containers (see $LS_OVERRIDE; delete it to undo)."
  return 0
}

# For run.sh / stop.sh / update.sh / uninstall.sh (cwd = the install folder).
ls_require_engine() {
  ls_select_engine "./.env" || exit 1
  if [ "${1:-}" = "running" ] && ! ls_engine_running; then
    if ls_fallback_engine; then
      ls_say "  [!] Podman is not responding - using Docker instead."
    else
      ls_err "The $ENGINE_NAME engine is not running. Start it first."
      ls_engine_hint
      exit 1
    fi
  fi
  ls_select_compose || exit 1
  ls_ensure_podman_socket || ls_say "  [!] Podman's API socket is not active - if compose fails, run: systemctl --user enable --now podman.socket"
}
# ---- end of engine.sh ------------------------------------------------------

# A terminal opened by a file manager closes the instant the installer ends and
# takes the output with it: wait for a key press unless an interactive shell started us.
ls_pause_on_exit

# How long to wait for a just-launched container engine (seconds).
DOCKER_WAIT_TIMEOUT="${LOCAL_SEARCH_DOCKER_TIMEOUT:-300}"
ENGINE_LAUNCHED=0
ls_select_engine || exit 1
if ! ls_engine_running; then
  say "  ${YELLOW}[!]${RESET} The $ENGINE_NAME engine is not running - trying to start it..."
  if ls_start_engine; then
    ENGINE_LAUNCHED=1
    say "  Launched $ENGINE_NAME in the background. Answer the next questions while"
    say "  it boots - the installer waits for the engine before pulling images."
  elif ls_fallback_engine; then
    say "  ${YELLOW}[!]${RESET} Podman is installed but is not responding; Docker is running - using Docker instead."
  else
    err "Could not start the $ENGINE_NAME engine automatically."
    say ""
    say "Start it manually, then re-run this installer:"
    ls_engine_hint
    exit 1
  fi
fi
ls_select_compose || exit 1
ok "$ENGINE_NAME and its compose tool are available ($DC)."

SRC="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_TARGET="$HOME/local-search"

llm_intro() {
  say "  Lets Firecrawl do AI extraction (/v1/extract) and summaries."
  say "  Recommended: LM Studio -> http://localhost:1234/v1"
}

# The Firecrawl container reaches a host-side server through host.docker.internal.
ask_llm() {
  LLM_URL=""; LLM_KEY=""; LLM_MODEL=""
  printf "    Base URL Endpoint [Enter = http://localhost:1234/v1]: "
  read -r LLM_URL || true
  [ -z "$LLM_URL" ] && LLM_URL="http://localhost:1234/v1"
  printf "    API Key [Enter to skip]: "
  read -r LLM_KEY || true
  printf "    Model name [Enter to skip]: "
  read -r LLM_MODEL || true
  OPENAI_BASE_URL="${LLM_URL/http:\/\/localhost/http:\/\/host.docker.internal}"
  OPENAI_BASE_URL="${OPENAI_BASE_URL/http:\/\/127.0.0.1/http:\/\/host.docker.internal}"
  OPENAI_API_KEY="${LLM_KEY:-placeholder}"
  MODEL_NAME="$LLM_MODEL"
  say "    (Container will reach it at: $OPENAI_BASE_URL)"
}

quick_setup() {
  TARGET="$DEFAULT_TARGET"
  mkdir -p "$TARGET"
  TARGET="$(cd "$TARGET" && pwd)"
  SEARXNG_PORT=9990
  FIRECRAWL_PORT=9991
  BROWSER_ENGINE="playwright"
  PW_URL="http://playwright-service:3000/scrape"
  OPENAI_BASE_URL=""; OPENAI_API_KEY=""; MODEL_NAME=""
  FC_API_KEY=""; FC_API_URL=""
}

full_setup() {
hdr "Step 1 of 6: Install location"
say "  Default: $DEFAULT_TARGET"
printf "  Target folder [press Enter for default]: "
read -r TARGET
[ -z "$TARGET" ] && TARGET="$DEFAULT_TARGET"
if [ "${TARGET#\~}" != "$TARGET" ]; then TARGET="$HOME${TARGET#\~}"; fi  # POSIX tilde expansion
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
say "  Using: $TARGET"

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [ "$p" -ge 1 ] 2>/dev/null || return 1
  [ "$p" -le 65535 ] 2>/dev/null || return 1
  return 0
}

hdr "Step 2 of 6: SearXNG port (default 9990)"
while true; do
  printf "  Port for SearXNG [press Enter for 9990]: "
  read -r SEARXNG_PORT
  [ -z "$SEARXNG_PORT" ] && SEARXNG_PORT=9990
  if validate_port "$SEARXNG_PORT"; then break; fi
  say "  ${YELLOW}[!]${RESET} '$SEARXNG_PORT' is not a valid port (1-65535)."
done

hdr "Step 3 of 6: Firecrawl port (default 9991)"
while true; do
  printf "  Port for Firecrawl [press Enter for 9991]: "
  read -r FIRECRAWL_PORT
  [ -z "$FIRECRAWL_PORT" ] && FIRECRAWL_PORT=9991
  if ! validate_port "$FIRECRAWL_PORT"; then
    say "  ${YELLOW}[!]${RESET} '$FIRECRAWL_PORT' is not a valid port (1-65535)."
    continue
  fi
  if [ "$FIRECRAWL_PORT" = "$SEARXNG_PORT" ]; then
    say "  ${YELLOW}[!]${RESET} Firecrawl port must differ from SearXNG port."
    continue
  fi
  break
done

hdr "Step 4 of 6: Browser rendering engine (default: Playwright)"
say "  Firecrawl needs a headless-browser service for JS-rendered pages."
say "  Playwright  - the classic Firecrawl engine (default)."
say "  Browserless - stealth mode (masks automation fingerprints);"
say "                better at avoiding Cloudflare/bot-check blocks."
printf "  Use Browserless instead of Playwright? [y/N]: "
read -r USE_BROWSERLESS
if [ "$(lower "$USE_BROWSERLESS")" = "y" ]; then
  BROWSER_ENGINE="browserless"
  PW_URL="http://browserless:3000/scrape"
else
  BROWSER_ENGINE="playwright"
  PW_URL="http://playwright-service:3000/scrape"
fi
say "    (Engine: $BROWSER_ENGINE)"

hdr "Step 5 of 6: LLM (optional)"
llm_intro
printf "  Connect LLM now? [y/N]: "
USE_LLM=""
read -r USE_LLM || true
OPENAI_BASE_URL=""; OPENAI_API_KEY=""; MODEL_NAME=""
if [ "$(lower "$USE_LLM")" = "y" ]; then
  ask_llm
fi

hdr "Step 6 of 6: Firecrawl account (optional)"
say "  The extra tools (research agent, live-page interact, file parse,"
say "  monitors, paper research, GitHub/developer search) only work"
say "  with a Firecrawl account API key (paid cloud service):"
say "    https://www.firecrawl.dev"
say "  Answer N to install only the free local tools (default)."
printf "  Add a Firecrawl account now? [y/N]: "
USE_FC=""
read -r USE_FC || USE_FC=""
FC_API_KEY=""; FC_API_URL=""
if [ "$(lower "$USE_FC")" = "y" ]; then
  FC_TRIES=0
  while true; do
    printf "    Firecrawl API key (from https://www.firecrawl.dev): "
    if ! read -r FC_API_KEY; then FC_API_KEY=""; break; fi
    [ -n "$FC_API_KEY" ] && break
    FC_TRIES=$((FC_TRIES + 1))
    if [ "$FC_TRIES" -ge 3 ]; then
      say "    ${YELLOW}[!]${RESET} no API key entered - continuing WITHOUT a Firecrawl account."
      FC_API_KEY=""
      break
    fi
    say "    ${YELLOW}[!]${RESET} the API key cannot be empty - try again."
  done
  if [ -n "$FC_API_KEY" ]; then
    printf "    Firecrawl API URL [press Enter for https://api.firecrawl.dev]: "
    read -r FC_API_URL || FC_API_URL=""
    [ -z "$FC_API_URL" ] && FC_API_URL="https://api.firecrawl.dev"
  fi
fi
}

say "${BOLD}============================================================${RESET}"
say "${BOLD}  Setup type${RESET}"
say "${BOLD}============================================================${RESET}"
say "  1) Minimal installation"
say "  2) Minimal + LLM Extraction"
say "  3) Full installation"
say "  Options 1 and 2 use: $DEFAULT_TARGET, SearXNG 9990, Firecrawl 9991,"
say "  Playwright engine, no Firecrawl account. Option 2 also asks for an LLM."
say "  You can change any of this later by editing .env and running"
say "  ./update.sh."
printf "  Choose 1, 2 or 3 [Enter = 1]: "
while :; do
  SETUP_MODE=""
  read -r SETUP_MODE || true
  [ -z "$SETUP_MODE" ] && SETUP_MODE=1
  case "$SETUP_MODE" in 1|2|3) break ;; esac
  printf "  Please enter 1, 2 or 3: "
done
case "$SETUP_MODE" in
  3) full_setup ;;
  2) quick_setup
     hdr "LLM extraction"
     llm_intro
     ask_llm
     say "  Using defaults - see summary below." ;;
  *) quick_setup; say "  Using defaults - see summary below." ;;
esac

echo
say "${BOLD}============================================================${RESET}"
say "${BOLD}  Summary${RESET}"
say "  Folder:         $TARGET"
say "  SearXNG port:   $SEARXNG_PORT"
say "  Firecrawl port: $FIRECRAWL_PORT"
say "  Browser engine: $BROWSER_ENGINE"
say "  Container tool: $ENGINE_NAME ($DC)"
say "  Agent skill:    $HOME/.agents/skills/local-web-search"
if [ -n "$OPENAI_BASE_URL" ]; then
  say "  LLM endpoint:   $OPENAI_BASE_URL  $MODEL_NAME"
else
  say "  LLM endpoint:   (none - enable later by editing .env)"
fi
if [ -n "$FC_API_KEY" ]; then
  say "  Firecrawl acct: $FC_API_URL  (account tools installed)"
else
  say "  Firecrawl acct: (none - free local tools only)"
fi
say "${BOLD}============================================================${RESET}"
printf "Proceed with install? [Y/n]: "
read -r CONFIRM
if [ "$(lower "$CONFIRM")" = "n" ]; then say "Install cancelled."; exit 0; fi

mkdir -p "$TARGET/config/searxng" "$TARGET/local-web-search/scripts"

if [ -f "$TARGET/.env" ]; then
  LDT="$(date +%Y%m%d%H%M%S)"
  cp "$TARGET/.env" "$TARGET/.env.bak.$LDT"
  say "  Backed up existing .env to .env.bak.$LDT"
fi

say "Copying all project files..."

# --- config/searxng/settings.yml ---
if [ -f "$SRC/config/searxng/settings.yml" ]; then
  cp "$SRC/config/searxng/settings.yml" "$TARGET/config/searxng/settings.yml"
else
  say "  [embedded] config/searxng/settings.yml  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/config/searxng/settings.yml" <<'EOF_CONFIG_SEARXNG_SETTINGS_YML'
# =============================================================================
#  SearXNG settings for local-search
# =============================================================================
#  Pre-configured for AI / local-model use:
#    * search.formats includes "json"  -> lets models query the JSON API
#    * server.limiter: false           -> no rate-limiting on API calls
#    * server.public_instance: false   -> private instance defaults
#    * secret_key placeholder          -> installer replaces with a random key
#
#  "use_default_settings: true" inherits all upstream defaults (engines,
#  plugins, etc.) so only the overrides below take effect.
# =============================================================================

use_default_settings: true

general:
  debug: false
  instance_name: "Local Search"
  privacypolicy_url: false
  contact_link: false

search:
  safe_search: 0
  autocomplete: ""
  default_lang: "en"
  formats:
    - html
    - json

server:
  secret_key: "32645fb30c6d4cbe217c67956d3db00d377b4fded18455497b073b3b0dc4253c"
  bind_address: "0.0.0.0"
  port: 8080
  image_proxy: true
  limiter: false
  public_instance: false

ui:
  static_use_hash: true

outgoing:
  request_timeout: 10.0
  max_request_timeout: 15.0
EOF_CONFIG_SEARXNG_SETTINGS_YML
fi

# --- docker-compose.yml ---
if [ -f "$SRC/docker-compose.yml" ]; then
  cp "$SRC/docker-compose.yml" "$TARGET/docker-compose.yml"
else
  say "  [embedded] docker-compose.yml  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/docker-compose.yml" <<'EOF_DOCKER_COMPOSE_YML'
# =============================================================================
#  Local Search — Firecrawl + SearXNG (local web-browsing system for AI models)
# =============================================================================
#  This Compose file is consumed by the installers (install-local-search.bat /
#  install-local-search.sh). The host ports and credentials are injected from
#  the generated .env file (created at install time).
#
#  Services:
#    searxng             metasearch + JSON API        -> host ${SEARXNG_PORT}
#    firecrawl           scrape/crawl/search/map API  -> host ${FIRECRAWL_PORT}
#    playwright-service  JS rendering for Firecrawl (profile: playwright)
#    browserless         stealth JS rendering for Firecrawl (profile: browserless)
#    redis               queue for Firecrawl
#    rabbitmq            message broker for Firecrawl
#    nuq-postgres        job state DB for Firecrawl
#
#  Only ONE of playwright-service / browserless actually starts: the
#  installer's "Browser rendering engine" question writes COMPOSE_PROFILES
#  to .env (default "playwright") to pick which one, and points
#  PLAYWRIGHT_MICROSERVICE_URL at it. The other stays defined but dormant.
#
#  Only the two host ports below are published. Everything else stays on the
#  private "local-search-net" bridge network.
#
#  Works with Docker AND Podman (the Linux/macOS installer prefers Podman when
#  both are installed). Two things make that safe:
#    * Every image is fully qualified (docker.io/..., ghcr.io/...), so Podman
#      never has to guess a registry or ask "which one?" for a short name -
#      images only ever come from Docker Hub and GHCR.
#    * SearXNG's bind-mounted config folder is tuned from .env (written by
#      install-local-search.sh) - see the SEARXNG_MOUNT_OPTS /
#      SEARXNG_FORCE_OWNERSHIP notes on the searxng service.
# =============================================================================

name: local-search

services:

  # --------------------------------------------------------------------------
  # SearXNG — privacy-respecting metasearch engine, exposed as a JSON API.
  # Powers both your AI models (direct JSON queries) and Firecrawl's /v1/search.
  # --------------------------------------------------------------------------
  searxng:
    image: docker.io/searxng/searxng:latest
    container_name: local-search-searxng
    ports:
      - "${SEARXNG_PORT:-9990}:8080"
    # SEARXNG_MOUNT_OPTS (from .env) appends extra bind-mount options. On hosts
    # with SELinux (Fedora, RHEL, ...) the installer sets it to ",z" so the
    # container may read /etc/searxng; without that label SearXNG dies at
    # start-up with "chown/cp/sed: ... Permission denied" and restart-loops.
    # It is empty everywhere else (Windows, macOS, Ubuntu, ...).
    volumes:
      - ./config/searxng:/etc/searxng:rw${SEARXNG_MOUNT_OPTS:-}
    environment:
      - SEARXNG_BASE_URL=http://localhost:${SEARXNG_PORT:-9990}/
      - UWSGI_WORKERS=4
      - UWSGI_THREADS=4
      - SEARXNG_SECRET=${SEARXNG_SECRET}
      # The image's entrypoint chowns the mounted config folder to its own
      # "searxng" user unless this is "false". Rootless Podman would turn the
      # host files into a sub-UID you cannot edit or delete, so the installer
      # sets "false" there; it stays "true" (the image default) otherwise.
      - FORCE_OWNERSHIP=${SEARXNG_FORCE_OWNERSHIP:-true}
    restart: unless-stopped
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # Firecrawl API server (the public-facing scraping/crawl/search service).
  # --------------------------------------------------------------------------
  firecrawl:
    image: ghcr.io/firecrawl/firecrawl:latest
    container_name: local-search-firecrawl
    ports:
      - "${FIRECRAWL_PORT:-9991}:3002"
    environment:
      - PORT=3002
      - HOST=0.0.0.0
      - ENV=local
      - REDIS_URL=redis://redis:6379
      - REDIS_RATE_LIMIT_URL=redis://redis:6379
      - PLAYWRIGHT_MICROSERVICE_URL=${PLAYWRIGHT_MICROSERVICE_URL:-http://playwright-service:3000/scrape}
      - USE_DB_AUTHENTICATION=false
      - BULL_AUTH_KEY=${BULL_AUTH_KEY}
      - LOGGING_LEVEL=${LOGGING_LEVEL:-info}
      - BLOCK_MEDIA=false
      # Firecrawl's SSRF guard refuses private/reserved addresses, but proxy and VPN tools (Clash
      # fake-IP, WARP, ...) hand those out for public sites, so every scrape would fail. This stack
      # is localhost-only: the guard is off here and in playwright-service.
      - ALLOW_LOCAL_WEBHOOKS=true
      - SEARXNG_ENDPOINT=http://searxng:8080
      - POSTGRES_HOST=nuq-postgres
      - POSTGRES_PORT=5432
      - POSTGRES_DB=${POSTGRES_DB:-firecrawl}
      - POSTGRES_USER=${POSTGRES_USER:-firecrawl}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - NUQ_RABBITMQ_URL=amqp://${RABBITMQ_USER:-firecrawl}:${RABBITMQ_PASSWORD}@rabbitmq:5672
      # ---- Optional AI features (set in .env to enable /v1/extract + summary) ----
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}
      - OPENAI_BASE_URL=${OPENAI_BASE_URL:-}
      - OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-}
      - MODEL_NAME=${MODEL_NAME:-}
      - MODEL_EMBEDDING_NAME=${MODEL_EMBEDDING_NAME:-}
    command: ["node", "dist/src/harness.js", "--start-docker"]
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    extra_hosts:
      - "host.docker.internal:host-gateway"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
        compress: "true"
    # NOTE: playwright-service / browserless are deliberately NOT listed here.
    # They are profile-gated (only one of them runs), and podman-compose crashes
    # with "KeyError: 'browserless'" when a service depends on one that its
    # profile disabled. Docker only ever honoured that dependency as start
    # ORDER (service_started + required: false, never readiness), and Firecrawl
    # reaches the browser service per scrape request, not at start-up, so
    # nothing is lost. Keep profile-gated services out of every depends_on.
    depends_on:
      redis:
        condition: service_started
      searxng:
        condition: service_started
      nuq-postgres:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # Playwright headless browser service — does the actual JS-rendered
  # fetching. Only starts when COMPOSE_PROFILES=playwright (the installer's
  # default answer to "Browser rendering engine").
  # --------------------------------------------------------------------------
  playwright-service:
    image: ghcr.io/firecrawl/playwright-service:latest
    container_name: local-search-playwright
    profiles: ["playwright"]
    environment:
      - PORT=3000
      - BLOCK_MEDIA=false
      - ALLOW_LOCAL_WEBHOOKS=true
      - MAX_CONCURRENT_PAGES=10
    restart: unless-stopped
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # Browserless (community edition) — stealth headless Chromium that does the
  # actual JS-rendered fetching for Firecrawl. DEFAULT_STEALTH=true applies
  # the built-in stealth patches (masks automation fingerprints such as
  # navigator.webdriver) to every request without needing a ?stealth query
  # param, which helps pages fronted by Cloudflare and similar bot checks.
  # Only starts when COMPOSE_PROFILES=browserless (the installer's "Use
  # Browserless instead?" answer).
  # --------------------------------------------------------------------------
  browserless:
    image: ghcr.io/browserless/chromium:latest
    container_name: local-search-browserless
    profiles: ["browserless"]
    environment:
      - PORT=3000
      - TOKEN=${BROWSERLESS_TOKEN:-}
      - DEFAULT_STEALTH=true
      - CONCURRENT=10
      - MAX_CONCURRENT_SESSIONS=10
    restart: unless-stopped
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # Redis — Firecrawl queue / rate-limiting store.
  # --------------------------------------------------------------------------
  redis:
    image: docker.io/library/redis:alpine
    container_name: local-search-redis
    volumes:
      - redis-data:/data
    restart: unless-stopped
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # RabbitMQ — message broker used by Firecrawl's job workers.
  # --------------------------------------------------------------------------
  rabbitmq:
    image: docker.io/library/rabbitmq:3-management
    container_name: local-search-rabbitmq
    environment:
      - RABBITMQ_DEFAULT_USER=${RABBITMQ_USER:-firecrawl}
      - RABBITMQ_DEFAULT_PASS=${RABBITMQ_PASSWORD}
    volumes:
      - rabbitmq-data:/var/lib/rabbitmq
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "ping"]
      interval: 5s
      timeout: 10s
      retries: 10
      start_period: 30s
    restart: unless-stopped
    networks:
      - local-search-net

  # --------------------------------------------------------------------------
  # nuq-postgres — Firecrawl job-state database (pg_cron enabled image).
  # --------------------------------------------------------------------------
  nuq-postgres:
    image: ghcr.io/firecrawl/nuq-postgres:latest
    container_name: local-search-postgres
    command: postgres -c cron.database_name=${POSTGRES_DB:-firecrawl}
    environment:
      - POSTGRES_DB=${POSTGRES_DB:-firecrawl}
      - POSTGRES_USER=${POSTGRES_USER:-firecrawl}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-firecrawl} -d ${POSTGRES_DB:-firecrawl}"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 30s
    restart: unless-stopped
    networks:
      - local-search-net

networks:
  local-search-net:
    driver: bridge

volumes:
  redis-data:
  postgres-data:
  rabbitmq-data:
EOF_DOCKER_COMPOSE_YML
fi

# --- .env.example ---
if [ -f "$SRC/.env.example" ]; then
  cp "$SRC/.env.example" "$TARGET/.env.example"
else
  say "  [embedded] .env.example  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/.env.example" <<'EOF__ENV_EXAMPLE'
# =============================================================================
#  Local Search — example environment file
# =============================================================================
#  The installer (install-local-search.bat / install-local-search.sh) generates
#  a REAL .env file at install time with:
#    * the host ports you chose
#    * cryptographically-random passwords/keys (do NOT use the values below
#      in production — they are placeholders only)
#
#  This file is documentation. To change settings after install, edit the .env
#  in your install folder, then run Update.bat / update.sh (or restart).
# =============================================================================

# ---- Host ports (what you connect to from your machine) ----
SEARXNG_PORT=9990
FIRECRAWL_PORT=9991

# ---- SearXNG instance secret (random — installer generates) ----
SEARXNG_SECRET=replace-with-64-char-random-hex

# ---- Container engine (Linux/macOS installer: install-local-search.sh) ----
#   podman or docker. The installer prefers Podman when it is installed (even if
#   Docker is too) and records what it used here, so run.sh / stop.sh / update.sh
#   keep using the same engine. Set it yourself to switch, then run update.sh.
#   To force the choice for one run:  LOCAL_SEARCH_ENGINE=docker ./install-local-search.sh
LOCAL_SEARCH_ENGINE=podman

# ---- SearXNG config-folder mount (installer decides; leave as written) ----
#   SEARXNG_MOUNT_OPTS=,z            hosts with SELinux (Fedora, RHEL, ...): relabels
#                                    config/searxng so the container may read it.
#                                    Without it SearXNG restart-loops with
#                                    "chown/cp/sed ... Permission denied". Empty elsewhere.
#   SEARXNG_FORCE_OWNERSHIP=false    rootless Podman: stops SearXNG's entrypoint from
#                                    re-owning the folder (it would become a sub-UID you
#                                    cannot edit). "true" (the image default) elsewhere.
SEARXNG_MOUNT_OPTS=
SEARXNG_FORCE_OWNERSHIP=true

# ---- Firecrawl internal credentials (installer generates random values) ----
BULL_AUTH_KEY=replace-with-64-char-random-hex
POSTGRES_DB=firecrawl
POSTGRES_USER=firecrawl
POSTGRES_PASSWORD=replace-with-64-char-random-hex
RABBITMQ_USER=firecrawl
RABBITMQ_PASSWORD=replace-with-64-char-random-hex

# ---- Browser rendering engine for Firecrawl (installer Step 4) ----
#   playwright (default): ghcr.io/firecrawl/playwright-service
#   browserless:          ghcr.io/browserless/chromium (stealth mode, better
#                          block avoidance on Cloudflare-fronted sites)
#   COMPOSE_PROFILES selects which service actually starts; PLAYWRIGHT_MICROSERVICE_URL
#   must point at the same one. To switch later, change both lines and run Update.bat/update.sh.
COMPOSE_PROFILES=playwright
PLAYWRIGHT_MICROSERVICE_URL=http://playwright-service:3000/scrape

# ---- Browserless token (only used if COMPOSE_PROFILES=browserless above; installer generates a random value regardless) ----
BROWSERLESS_TOKEN=replace-with-64-char-random-hex

# ---- Logging ----
LOGGING_LEVEL=info

# =============================================================================
#  Optional: connect a local (or remote) LLM so Firecrawl's /v1/extract and
#  "summary" features work. Any OpenAI-compatible endpoint will do.
#  LM Studio is the recommended default (priority over Ollama).
# =============================================================================

# ---- Option A (RECOMMENDED): LM Studio / any OpenAI-compatible local server ----
#   1. In LM Studio: Developer tab > "Start Server" on port 1234, load a model,
#      and ENABLE "Serve on local network" so the Firecrawl container can reach it.
#   2. NOTE: OPENAI_BASE_URL is read INSIDE the Firecrawl container. From there,
#      your host machine is "host.docker.internal", NOT "localhost". So use:
# OPENAI_BASE_URL=http://host.docker.internal:1234/v1
# OPENAI_API_KEY=lm-studio          # any non-empty string; LM Studio ignores it
# MODEL_NAME=local-model            # the model id loaded in LM Studio

# ---- Option B: remote OpenAI-compatible server (vLLM, llama.cpp server, etc.) ----
# OPENAI_BASE_URL=http://192.168.1.50:8000/v1
# OPENAI_API_KEY=placeholder
# MODEL_NAME=your-model-id

# ---- Option C (fallback): Ollama on the same host as Docker ----
# OLLAMA_BASE_URL=http://host.docker.internal:11434/api
# MODEL_NAME=qwen2.5:7b
# MODEL_EMBEDDING_NAME=nomic-embed-text

# =============================================================================
#  Optional: Firecrawl account (paid cloud service) for the account-only
#  local-web-search tools (research agent, interact, parse, monitors, paper
#  research, GitHub/developer search).
#
#  The installer offers to write these for you (answer 'y' at the
#  "Add a Firecrawl account?" question, then paste your key). Without them
#  the installer skips those tools and installs only the free local ones.
#  The local-web-search scripts read these keys from THIS file;
#  FIRECRAWL_API_URL / FIRECRAWL_API_KEY environment variables override them.
#  (The Docker containers ignore these keys entirely.)
# =============================================================================
# FIRECRAWL_API_URL=https://api.firecrawl.dev
# FIRECRAWL_API_KEY=fc-your-key-here
EOF__ENV_EXAMPLE
fi

# --- README.md ---
if [ -f "$SRC/README.md" ]; then
  cp "$SRC/README.md" "$TARGET/README.md"
else
  say "  [embedded] README.md  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/README.md" <<'EOF_README_MD'
# 🔍 Local Search — a private web-browsing system for AI models

**SearXNG + Firecrawl + the local-web-search agent skill, running entirely on your machine, behind two local ports.**

Give any LLM — a local model in LM Studio, a cloud model, an agent, an MCP
client, or a plain chat UI — the ability to **search the web and read pages**
without sending a single request to a paid scraping API. Everything runs in
Docker on your computer; your queries, results, and page contents never leave
your network.

| What | URL (default) | Purpose |
|------|---------------|---------|
| **SearXNG**  | `http://localhost:9990` | Metasearch + JSON API. Aggregates Google/Bing/DuckDuckGo/etc. |
| **Firecrawl** | `http://localhost:9991` | Scrape / crawl / map / search / extract — returns clean Markdown. |
| **local-web-search** | `~/.agents/skills/local-web-search` | Bundled agent skill: search + read + auto-start the stack. |

> Both ports are fully configurable at install time. The defaults (`9990` and
> `9991`) are chosen to avoid clashing with common dev servers.

---

## Table of contents

1. [What you get](#what-you-get)
2. [Requirements](#requirements)
3. [Quick start (one-click install)](#quick-start-one-click-install)
4. [Managing the stack](#managing-the-stack)
5. [How it fits together](#how-it-fits-together)
6. [Using it with AI models](#using-it-with-ai-models)
   - [A. The bundled local-web-search skill (recommended)](#a-the-bundled-local-web-search-skill-recommended)
   - [B. Direct SearXNG JSON API](#b-direct-searxng-json-api)
   - [C. Direct Firecrawl REST API](#c-direct-firecrawl-rest-api)
   - [D. Connect an LLM (LM Studio, etc.)](#d-connect-an-llm-lm-studio-etc)
   - [E. Via an MCP server](#e-via-an-mcp-server)
   - [F. Via prompting (any chat UI)](#f-via-prompting-any-chat-ui)
   - [G. GUI integrations](#g-gui-integrations)
7. [Configuration reference](#configuration-reference)
8. [Troubleshooting](#troubleshooting)
9. [Updating & uninstalling](#updating--uninstalling)
10. [Development: full dev rig (rebuilding everything)](#development-full-dev-rig-rebuilding-everything)
11. [Security notes](#security-notes)
12. [Credits & licenses](#credits--licenses)

---

## What you get

A single Docker Compose stack of six running services on a private bridge
network (seven are defined, but the installer only starts one of the two
browser engines below), **plus** a ready-made agent skill that ties it all
together:

| Service | Image | Role |
|---------|-------|------|
| **searxng** | `searxng/searxng:latest` | Metasearch engine with **JSON output enabled** and the rate-limiter **disabled**, so models can query it programmatically. |
| **firecrawl** | `ghcr.io/firecrawl/firecrawl:latest` | The scraping/crawling/search API. Runs with `USE_DB_AUTHENTICATION=false` → **no API key needed** for local use. |
| **playwright-service** *(default engine)* | `ghcr.io/firecrawl/playwright-service:latest` | Headless Chromium for JavaScript-rendered pages — the classic Firecrawl engine. Starts when the installer's Step 4 answer is Playwright (the default). |
| **browserless** *(alternate engine)* | `ghcr.io/browserless/chromium:latest` | Stealth headless Chromium (Browserless CE, `DEFAULT_STEALTH=true`) for JavaScript-rendered pages; better at avoiding Cloudflare-style bot checks. Starts instead of Playwright when Step 4 is answered **y**. |
| **redis** | `redis:alpine` | Firecrawl job queue. |
| **rabbitmq** | `rabbitmq:3-management` | Firecrawl message broker. |
| **nuq-postgres** | `ghcr.io/firecrawl/nuq-postgres:latest` | Firecrawl job-state DB (pg_cron enabled). |

On top of the containers, the installer bundles **local-web-search** — a skill for
agents that load skills from `~/.agents/skills/` (`C:\Users\You\.agents\skills\`
on Windows). It gives the agent a complete web-research workflow: search via
SearXNG, read pages via Firecrawl, and even start the Docker stack
automatically when it's down. See [section A](#a-the-bundled-local-web-search-skill-recommended).

Only **two host ports** are published (`9990` and `9991` by default). Everything
else stays on the private `local-search-net` bridge network. Firecrawl's
`/v1/search` endpoint is automatically wired to SearXNG internally, so a single
Firecrawl call can both search *and* fetch full page content.

---

## Requirements

- **Docker** with the **Compose v2 plugin** (`docker compose`) — **or Podman** (Linux/macOS) with a compose provider.
  - Windows: [Docker Desktop](https://www.docker.com/products/docker-desktop/)
  - macOS: [Docker Desktop](https://www.docker.com/products/docker-desktop/), or Podman (`brew install podman docker-compose`, then `podman machine init && podman machine start`)
  - Linux, Docker: [Docker Engine](https://docs.docker.com/engine/install/) + the `docker-compose-plugin` package. Add your user to the `docker` group so you don't need `sudo`.
  - Linux, Podman (Fedora / RHEL / Debian / Ubuntu): `sudo dnf install podman docker-compose` (Debian/Ubuntu: `sudo apt install podman docker-compose-v2`). Both compose providers work — Compose v2 (`docker-compose`) and `podman-compose` (tested with 1.6.0). Rootless is fine.
  - **If both Podman and Docker are installed, the Linux/macOS installer uses Podman.** Force the other one with `LOCAL_SEARCH_ENGINE=docker ./install-local-search.sh`. The installer records its choice in `.env` (`LOCAL_SEARCH_ENGINE`) so `run.sh` / `update.sh` keep using the same engine. The Windows installer uses Docker Desktop.
- **~5 GB free disk** for images and data.
- **8 GB RAM / 4 CPU cores** recommended (Firecrawl plus its browser engine — Playwright or Browserless — is the heavy part; reduce resource limits in `docker-compose.yml` for smaller hosts).
- **Python 3.8+** for the bundled local-web-search skill scripts (optional but recommended — it's the easiest way to use the stack).
- *(Optional, for Firecrawl AI features)* **LM Studio** or any OpenAI-compatible endpoint, local or remote — see [section D](#d-connect-an-llm-lm-studio-etc).
- *(Optional, for MCP)* **Node.js 18+** so `npx firecrawl-mcp` works.

Verify your engine is ready:

```bash
docker info            # engine is running        (Podman: podman info)
docker compose version # v2 is installed         (Podman: podman compose version)
```

---

## Quick start (one-click install)

> **The installer is self-contained.** Every file it needs (`docker-compose.yml`, `config/searxng/settings.yml`, `.env.example`, the bundled `local-web-search` skill, all the run/stop/update/uninstall scripts, this README, and even the *other* platform's installer) is embedded inside it. Download **`install-local-search.bat`** (Windows) or **`install-local-search.sh`** (Linux/macOS) on its own and the installer will produce a complete, working folder and a run the stack.

Run **one** installer for your platform. First it asks which setup you want —
type **1**, **2** or **3** (or press **Enter** for **1**):

| Choice          | Setup                    | What it does                                                                                                                                                                                                                                                         |
| --------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1** (default) | Minimal installation     | Default folder, SearXNG on `9990`, Firecrawl on `9991`, the Playwright browser engine, no questions at all, no LLM, no Firecrawl account: a true one-click install.                                                                                                  |
| **2**           | Minimal + LLM extraction | The same defaults, plus three questions to connect an LLM (base URL, API key, model).                                                                                                                                                                                |
| **3**           | Full installation        | The full six-step setup — install folder, SearXNG port, Firecrawl port, a browser rendering engine (Playwright or Browserless), (optionally) an LLM, and (optionally) a Firecrawl account — with the same defaults offered at each step if you just press **Enter**. |

Either way it then generates
cryptographically-secure credentials, writes your `.env`, **installs the
local-web-search skill**, pulls the images, and starts the stack.

> **Engine isn't running?** No problem — the installer starts it for you: it
> launches Docker Desktop (Windows/macOS), the Docker service
> (`systemctl`/`service`, Linux) or the Podman machine (macOS) and waits up to
> 5 minutes for the engine while you answer the prompts. (Override the wait with
> the `LOCAL_SEARCH_DOCKER_TIMEOUT` env var, in seconds.) Rootless Podman on
> Linux has no daemon to start.

### Windows

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) — no need to open it first; the installer launches it automatically.
2. Double-click **`install-local-search.bat`** (or run it from a terminal).

```
============================================================
  Setup type
============================================================
  1) Minimal installation
  2) Minimal + LLM extraction
  3) Full installation
  Defaults: C:\Users\You\local-search, SearXNG 9990, Firecrawl 9991,
  Playwright engine, no Firecrawl account.
  Choose 1, 2 or 3 [Enter = 1]:
```

**1** skips every question and installs. **2** asks only for the LLM (base URL,
API key, model), then installs. **3** walks through the full setup:

```
--- Step 1 of 6: Install location ----------
  Target folder [press Enter for default]:            # C:\Users\You\local-search
--- Step 2 of 6: SearXNG port (default 9990) ------
  Port for SearXNG [press Enter for 9990]: 9990
--- Step 3 of 6: Firecrawl port (default 9991) ----
  Port for Firecrawl [press Enter for 9991]: 9991
--- Step 4 of 6: Browser rendering engine (default: Playwright) ---
  Use Browserless instead of Playwright? [y/N]:         # default: Playwright, see below
--- Step 5 of 6: LLM (optional) -------------------
  Connect LLM now? [y/N]:                               # default: no, see section D
--- Step 6 of 6: Firecrawl account (optional) -----
  Add a Firecrawl account now? [y/N]: n                 # default: skip, see below
```

### Linux & macOS

```bash
chmod +x install-local-search.sh
./install-local-search.sh
```

The prompts are the same. Defaults: install to `~/local-search`, SearXNG on
`9990`, Firecrawl on `9991`, Playwright as the browser engine, no Firecrawl
account (and an LLM only if you pick setup **2** or answer **y** in setup **3**). A stopped engine is started automatically
(Docker Desktop / Podman machine on macOS, `systemctl`/`service` on Linux).

The installer **prefers Podman** when it is installed (even if Docker is too),
pulls every image only from **Docker Hub (`docker.io`) and GHCR (`ghcr.io`)** —
the compose file uses fully-qualified names, so Podman never asks which registry
to use — and, once the stack is up, **checks that SearXNG really answers**,
printing its container state and last log lines when it does not. On
SELinux hosts (Fedora, RHEL, …) and with rootless Podman it also sets how
SearXNG's config folder is mounted (see `SEARXNG_MOUNT_OPTS` /
`SEARXNG_FORCE_OWNERSHIP` below).

> **One-click install.** The very first question is the setup type. Choice
> **1** (the Enter default) skips every question and installs with the defaults
> shown above; choice **2** asks only the three LLM questions; choice
> **3** goes through all six numbered steps below so you can customize
> anything. Either way you can still change your mind afterward by editing
> `.env` and running `Update.bat` / `./update.sh`.

> **The optional LLM (Step 5, or setup 2).** Any OpenAI-compatible endpoint
> works, local or remote: the installer asks for its base URL (default
> `http://localhost:1234/v1`, LM Studio), an API key (Enter to skip) and a
> model name (Enter to skip), and writes them to `.env`. The extraction tool
> `web_extract.py` and the skill's "LLM extraction" section are installed
> **only** when an LLM is connected; without one the installed skill does not
> mention them. See [section D](#d-connect-an-llm-lm-studio-etc).

> **The browser rendering engine (Step 4).** Firecrawl needs a headless
> browser to fetch JS-rendered pages. The default answer, **N**, keeps
> **Playwright** — the classic Firecrawl engine (`ghcr.io/firecrawl/playwright-service`).
> Answering **y** switches to **Browserless** (`ghcr.io/browserless/chromium`)
> instead, run in its built-in stealth mode, which masks common automation
> fingerprints (e.g. `navigator.webdriver`) and tends to get blocked less
> often by Cloudflare-style bot checks. Only the engine you pick is actually
> started — the installer writes `COMPOSE_PROFILES` and
> `PLAYWRIGHT_MICROSERVICE_URL` to `.env` accordingly. To switch later, edit
> those two lines in `.env` and run `Update.bat` / `./update.sh`.

> **The optional Firecrawl account (Step 6).** A few of the bundled skill's
> tools — the research agent, live-page `interact`, file `parse`, monitors,
> paper research, and GitHub/developer search — only work against Firecrawl's
> paid cloud API. The default answer is **N**: those tools are simply *not
> installed*, and the skill ships a leaner `SKILL.md` covering just the free
> local tools. Answer **y** instead and the installer asks for your API key
> (and API URL, default `https://api.firecrawl.dev`), stores them in your
> `.env`, and installs all 25 tools (26 with LLM extraction). You can change your mind later
> by re-running the installer and answering differently.

> **First run downloads ~3–4 GB of Docker images** (Playwright's and Browserless's
> images each bundle a full Chromium, so only the one you picked is pulled).
> Subsequent starts are a few seconds.

When it finishes you'll see:

```
SearXNG  (search + JSON API):  http://localhost:9990
Firecrawl (scrape/crawl API): http://localhost:9991
Agent skill: C:\Users\You\.agents\skills\local-web-search   (or ~/.agents/skills/local-web-search)
```

Open `http://localhost:9990` in a browser to see the SearXNG search UI — or,
if your agent loads skills from `~/.agents/skills/`, just ask it to research
something current and it will use **local-web-search** automatically (see
[section A](#a-the-bundled-local-web-search-skill-recommended)).

---

## Managing the stack

After install, the management scripts live **in your install folder**
(`C:\Users\You\local-search` on Windows, `~/local-search` on Linux/macOS).
They auto-detect their own location, so you can run them from anywhere by
double-clicking or `./`-ing them.

| Action | Windows | Linux / macOS |
|--------|---------|---------------|
| **Start** the stack | `Run.bat` | `./run.sh` |
| **Stop** (keep data) | `Stop.bat` | `./stop.sh` |
| **Update** images + apply `.env` changes + **re-sync the skill** | `Update.bat` | `./update.sh` |
| **Uninstall** (containers + volumes + skill, optional folder delete) | `Uninstall.bat` | `./uninstall.sh` |

- **Stop** only removes containers; your data volumes (Firecrawl job state,
  redis cache, rabbitmq/postgres data) are preserved.
- **Update** runs `docker compose pull` then `docker compose up -d` (`podman compose …` on Podman), so it
  both upgrades images **and** applies any port/LLM edits you made to `.env`;
  it also re-copies the bundled `local-web-search` skill into `~/.agents/skills/`.
- **Uninstall** runs `docker compose down -v` (deletes volumes + data),
  removes the `local-web-search` skill from `~/.agents/skills/local-web-search`, then
  optionally deletes the install folder. Pulled images are kept; reclaim them
  with `docker image prune -a` if desired.

---

## How it fits together

```
        your AI model / agent (local-web-search skill) / MCP client / chat UI
                      │
   ┌──────────────────┼─────────────────────┐
   ▼                                       ▼
http://localhost:9990            http://localhost:9991
   │ SearXNG                            │ Firecrawl API
   │  - /search?q=...&format=json       │  - /v1/scrape   (one URL -> markdown)
   │  - aggregates ~70 engines           │  - /v1/crawl    (whole site, async)
   │                                     │  - /v1/map      (site URL tree)
   │                                     │  - /v1/search   (-> uses SearXNG!)
   │                                     │  - /v1/extract  (-> uses your LLM)
   │◄────────── wired together ──────────┤  SEARXNG_ENDPOINT=http://searxng:8080
   │                                     │
   └─────── private docker network ──────┘
                 local-search-net
   also on it: playwright-service OR browserless (whichever you picked in Step 4), redis, rabbitmq, nuq-postgres
```

Four key wiring decisions the installer makes for you:

1. **SearXNG JSON + no limiter** — `config/searxng/settings.yml` sets
   `search.formats: [html, json]` and `server.limiter: false`, so models can hit
   `/search?format=json` without being blocked as a bot.
2. **Firecrawl → SearXNG** — the Firecrawl container sets
   `SEARXNG_ENDPOINT=http://searxng:8080`, so Firecrawl's `/v1/search` uses your
   local SearXNG instead of needing a third-party search provider.
3. **Firecrawl → browser engine** — `docker-compose.yml` defines both
   `playwright-service` and `browserless` behind Compose profiles; `.env`'s
   `COMPOSE_PROFILES` (set by Step 4) enables just one, and
   `PLAYWRIGHT_MICROSERVICE_URL` points Firecrawl at it.
4. **local-web-search skill auto-install** — the installer copies the bundled skill to
   `~/.agents/skills/local-web-search/` (add/override) and records the install path in
   an `install-dir.txt` hint inside the skill, so the skill finds the stack even
   if you installed to a custom folder and Docker isn't running yet. Without a
   configured Firecrawl account it installs only the free local tools and a
   matching core-only `SKILL.md`.

---

## Using it with AI models

There are **seven** ways to use this system, from lowest to highest
integration. Pick what fits your stack — you can mix and match.

### A. The bundled local-web-search skill (recommended)

The installer ships with **local-web-search**, an agent skill that turns any
skill-loading agent into a web researcher with zero configuration. If your
agent reads skills from `~/.agents/skills/`
(`C:\Users\You\.agents\skills\` on Windows), it's already available after
install — restart the agent if it was running.

The installer:
- puts a copy in `<install folder>/local-web-search/`, and
- **automatically installs (add/override)** it into
  `~/.agents/skills/local-web-search/`.

What the skill does for the agent:

- **Finds the stack automatically.** It reads the real ports from your `.env`
  (so custom install-time ports just work) and locates the install folder via
  the compose labels on the running containers, the installer-recorded
  `install-dir.txt` hint, or `~/local-search` — no hardcoded anything.
- **Self-heals a down stack — no warm-up step.** If the Docker engine or the
  containers are down when a search/scrape runs, the script boots the engine
  (Docker Desktop / `systemctl start docker`), runs the same `docker compose
  up -d` that `Run.bat` / `run.sh` use, waits for the endpoints, and retries
  the request — so the agent calls the search/scrape scripts directly, even
  in an old conversation where the stack has since gone down
  (`ensure_stack.py` remains available as an optional pre-flight check). The
  stack is **never stopped** by the scripts (stopping is your job, via
  `Stop.bat` / `stop.sh`).
- **Searches the web.** `web_search.py "query"` prints the top results as
  `title / url / snippet`, with `--limit`, `--time-range day|week|month`, and
  `--categories it,news,general` options.
- **Reads pages.** `web_scrape.py <url>` returns the page as clean Markdown
  (truncated at 20,000 chars; raise with `--max-chars`).
- **Reads YouTube transcripts.** `web_youtube_transcript.py <video_id | url> [--lang en,de]`
  prints a video's captions as `[MM:SS] text` lines. It talks directly to
  YouTube — no Docker stack, no self-heal, no account needed — through
  **yt-dlp** (`pip install -U "yt-dlp[default]"`, plus Deno or Node.js 22+ on
  `PATH`). YouTube now guards the captions of a growing share of videos with a
  "PO token" that plain scrapers such as `youtube-transcript-api` cannot produce
  (they get an empty answer); yt-dlp can. The older package is kept only as a
  fallback for videos that are not behind the token yet.
- **Exposes the full Firecrawl MCP surface — 24 tools.** Besides search and
  scrape, the skill ships scripts mirroring every Firecrawl MCP tool:
  `web_map.py` (enumerate a site's URLs), `web_crawl.py` /
  `web_crawl_status.py` (multi-page crawls), `web_agent.py` /
  `web_agent_status.py` (async research agent), `web_interact.py` /
  `web_interact_stop.py` (live browser sessions), `web_parse.py` (local
  PDF/Word/HTML/... documents), eight `web_monitor_*.py` scripts (recurring
  change tracking), five `web_research_*.py` scripts (biomedical + arXiv
  paper search, citation graph, full-text reading), `web_github_search.py`
  (indexed GitHub issues/PRs/READMEs), and `web_developer_search.py` (an
  index built for coding agents). Every script self-heals the stack, prints
  clean output, and supports `--json` for the raw API response.
- **Optional account features.** The research agent, interact, parse,
  monitors, paper research, and developer search are Firecrawl account
  features (paid cloud API). The installer's "Add a Firecrawl account?"
  question decides how they're handled: **N** (default) skips them — the
  skill is installed with only the free local tools (search, scrape, map,
  crawl, crawl status, YouTube transcripts) and a core-only `SKILL.md` that
  doesn't mention the account tools; **y** installs all 25 tools (26 with LLM extraction) and writes
  `FIRECRAWL_API_URL` + `FIRECRAWL_API_KEY` into your `.env` so those
  scripts call the cloud API automatically (the same env var names the
  official firecrawl-mcp server uses, if you prefer `export`ing them).

Manual usage (exactly what the agent runs — no separate start step needed):

```bash
python ~/.agents/skills/local-web-search/scripts/web_search.py "latest python release"
python ~/.agents/skills/local-web-search/scripts/web_scrape.py "https://example.com"
# a few of the other tools:
python ~/.agents/skills/local-web-search/scripts/web_map.py "https://example.com"
python ~/.agents/skills/local-web-search/scripts/web_crawl.py "https://example.com" --max-pages 10
python ~/.agents/skills/local-web-search/scripts/web_parse.py "report.pdf"
python ~/.agents/skills/local-web-search/scripts/web_youtube_transcript.py "dQw4w9WgXcQ"
# optional pre-flight check / status report:
python ~/.agents/skills/local-web-search/scripts/ensure_stack.py --check
```

The full agent-facing instructions live in the skill's `SKILL.md`. Keeping the
skill fresh is automatic: `Update.bat` / `./update.sh` re-syncs it, and
re-running the installer overwrites it. Uninstalling removes it.

> The skill only needs **Python 3.8+** on the host — no API keys, no MCP
> support required from the agent. Every tool is stdlib-only except
> `web_youtube_transcript.py`, which needs **yt-dlp**
> (`pip install -U "yt-dlp[default]"`) and a JavaScript runtime (Deno or Node.js 22+).

---

### B. Direct SearXNG JSON API

The simplest possible integration: hit SearXNG's JSON endpoint and feed the
results into any model's context. No SDK, no key, no MCP.

```bash
# Search the web, return JSON, show the top 5 results
curl -s "http://localhost:9990/search?q=latest+AI+news&format=json" \
  | jq '.results[:5] | .[] | {title, url, content}'
```

Useful query params: `&pageno=2`, `&categories=it,images`, `&time_range=day`,
`&language=en`, `&engines=google,bing,duckduckgo`.

In Python:

```python
import requests
r = requests.get("http://localhost:9990/search", params={
    "q": "rust async runtime tokio",
    "format": "json",
    "language": "en",
}).json()
for hit in r["results"][:5]:
    print(hit["title"], "->", hit["url"])
    print(hit.get("content", "")[:200])
```

> SearXNG returns titles, URLs, and short content snippets — perfect for a
> "search then summarize" agent loop. For **full page text**, use Firecrawl (C).

---

### C. Direct Firecrawl REST API

Firecrawl turns any URL into clean Markdown/HTML/JSON — ideal for RAG. Because
the self-hosted instance runs with `USE_DB_AUTHENTICATION=false`, **no API key
is required** (you can send any `Authorization: Bearer …` header, or none).

#### Scrape a single page → Markdown

```bash
curl -s -X POST http://localhost:9991/v1/scrape \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","formats":["markdown"]}' \
  | jq '.data.markdown'
```

#### Search the web (uses your SearXNG internally) + return full content

```bash
curl -s -X POST http://localhost:9991/v1/search \
  -H "Content-Type: application/json" \
  -d '{"query":"what is rust programming language","limit":5}' \
  | jq '.data[:3] | .[] | {title, url, markdown}'
```

#### Crawl a whole site (async)

```bash
# 1) start the crawl
JOB=$(curl -s -X POST http://localhost:9991/v1/crawl \
  -H "Content-Type: application/json" \
  -d '{"url":"https://docs.example.com","limit":20}' | jq -r .id)

# 2) poll until status == "completed"
curl -s "http://localhost:9991/v1/crawl/$JOB" | jq '{status, completed, total}'
```

#### Map a site's URL tree (fast, no scraping)

```bash
curl -s -X POST http://localhost:9991/v1/map \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","limit":50}' | jq '.links'
```

#### Extract structured data with an LLM (needs section D configured)

```bash
curl -s -X POST http://localhost:9991/v1/extract \
  -H "Content-Type: application/json" \
  -d '{"urls":["https://example.com"],"prompt":"Extract the company name and a contact email"}' \
  | jq '.data'
```

#### Using the Firecrawl SDKs (Node / Python)

Self-host works with the official SDKs — point them at your local URL and pass
any non-empty string as the key:

**Node.js**
```js
import Firecrawl from "@mendable/firecrawl-js";

const fc = new Firecrawl({
  apiKey: "fc-local",              // any non-empty string; self-host doesn't validate
  apiUrl: "http://localhost:9991", // <-- point at your local instance
});

const { data } = await fc.scrapeUrl("https://example.com", { formats: ["markdown"] });
console.log(data.markdown);
```

**Python**
```python
from firecrawl import FirecrawlApp

fc = FirecrawlApp(api_key="fc-local", api_url="http://localhost:9991")
result = fc.scrape_url("https://example.com", params={"formats": ["markdown"]})
print(result["markdown"])
```

---

### D. Connect an LLM (LM Studio, etc.)

By default, Firecrawl's `/v1/scrape`, `/v1/crawl`, `/v1/map`, and `/v1/search`
work **without any LLM**. To unlock **`/v1/extract`** (AI extraction) and the
`summary` output format, point Firecrawl at any **OpenAI-compatible** endpoint.
**LM Studio is the recommended default** (priority over Ollama).

#### Recommended: LM Studio

1. Install [LM Studio](https://lmstudio.ai/), download a model (e.g. `Qwen2.5-7B-Instruct`).
2. Go to the **Developer** tab → **Start Server** on port `1234` (default).
3. **Enable "Serve on local network"** (required — Firecrawl runs in a container
   and reaches your host via `host.docker.internal`, which is your LAN IP, not
   `127.0.0.1`).
4. Either:
   - re-run the installer (setup **2**, or **3** and answer **y** to *"Connect
     LLM now?"*) — it auto-converts `http://localhost:1234/v1` →
     `http://host.docker.internal:1234/v1` and writes it into `.env`; **or**
   - edit `.env` directly and set:
     ```env
     OPENAI_BASE_URL=http://host.docker.internal:1234/v1
     OPENAI_API_KEY=lm-studio
     MODEL_NAME=<the model id loaded in LM Studio>
     ```
5. Apply with `Update.bat` / `./update.sh`.

#### Other OpenAI-compatible servers (vLLM, llama.cpp `server`, text-generation-inference, LocalAI, …)

```env
OPENAI_BASE_URL=http://<host-or-ip>:<port>/v1
OPENAI_API_KEY=placeholder      # any non-empty string if your server ignores it
MODEL_NAME=<model id from GET /v1/models>
```

For a remote server on another machine, use its IP directly (e.g.
`http://192.168.1.50:8000/v1`). For a server on the **same host as Docker**, use
`http://host.docker.internal:<port>/v1`.

#### Fallback: Ollama

If you prefer Ollama, set (Firecrawl reads `OLLAMA_BASE_URL`):

```env
OLLAMA_BASE_URL=http://host.docker.internal:11434/api
MODEL_NAME=qwen2.5:7b
MODEL_EMBEDDING_NAME=nomic-embed-text
```

Restart with `Update.bat` / `./update.sh`, then `/v1/extract` routes to Ollama.

---

### E. Via an MCP server

The official [**Firecrawl MCP server**](https://github.com/firecrawl/firecrawl-mcp-server)
exposes `firecrawl_search`, `firecrawl_scrape`, `firecrawl_crawl`, `firecrawl_map`,
`firecrawl_extract`, and research tools to any MCP-compatible client. Point it at
your local Firecrawl with `FIRECRAWL_API_URL`.

#### Claude Desktop (`claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "firecrawl": {
      "command": "npx",
      "args": ["-y", "firecrawl-mcp"],
      "env": {
        "FIRECRAWL_API_URL": "http://localhost:9991",
        "FIRECRAWL_API_KEY": "fc-local"
      }
    }
  }
}
```

#### Cursor, VS Code, Windsurf, Continue, Cline, etc.

Same shape — add an `mcpServers` entry to that tool's config file
(`~/.cursor/mcp.json`, `.vscode/mcp.json`, `./codeium/windsurf/model_config.json`, …).

```json
{
  "mcpServers": {
    "firecrawl": {
      "command": "npx",
      "args": ["-y", "firecrawl-mcp"],
      "env": {
        "FIRECRAWL_API_URL": "http://localhost:9991",
        "FIRECRAWL_API_KEY": "fc-local"
      }
    }
  }
}
```

> The MCP server runs on your host (not in Docker), so it reaches Firecrawl at
> `http://localhost:9991`. **No real API key is needed** — `fc-local` is a
> placeholder; the self-hosted Firecrawl doesn't validate it. Requires Node.js
> 18+ for `npx`.

> **Note for local llama.cpp servers:** the Firecrawl MCP server ships very
> large tool definitions, which can exceed some local inference servers'
> limits (e.g. llama.cpp's `MAX_REPETITION_THRESHOLD` of 2000). If your local
> model fails to load the MCP tools, use the bundled **local-web-search skill**
> ([section A](#a-the-bundled-local-web-search-skill-recommended)) instead — it works
> with any model that can run a shell command, and is the recommended path for
> local setups anyway.

#### Run the MCP server over HTTP (optional)

```bash
HTTP_STREAMABLE_SERVER=true \
FIRECRAWL_API_URL=http://localhost:9991 \
FIRECRAWL_API_KEY=fc-local \
npx -y firecrawl-mcp
# -> http://localhost:3000/mcp
```

---

### F. Via prompting (any chat UI)

No MCP, no SDK, no code — just tell the model where the tools are. Paste this
system prompt into **LM Studio's chat**, **Open WebUI**, **ChatBox**, or any UI
that lets you set a system prompt and has a "web request"/function/tool feature:

```
You have two local web tools running on this machine. Use them whenever the
user asks about anything current or anything you're unsure about.

1) SEARCH the web (returns JSON: title, url, content for each hit):
   GET http://localhost:9990/search?q=<URL-ENCODED-QUERY>&format=json&language=en
   Read .results[] (each has .title, .url, .content).

2) READ a web page as clean Markdown (no API key needed):
   POST http://localhost:9991/v1/scrape   Content-Type: application/json
   body: {"url":"<URL>","formats":["markdown"]}
   Read .data.markdown.

Workflow: SEARCH to find URLs, then SCRAPE the most relevant 1–3 URLs for full
text, then answer with citations. If a search or scrape fails, retry once with a
different query/URL. Never invent URLs — only use ones returned by SearXNG.
```

For UIs that only let you paste URLs (no tool calling), the model can still
emit `curl` commands or instruct you to run them; or you can wire the endpoints
behind a tiny proxy. The point is: the moment a model can issue HTTP GET/POST to
`localhost:9990` and `localhost:9991`, it has full web access.

---

### G. GUI integrations

| App | How |
|-----|-----|
| **Open WebUI** | Settings → Web Search → SearXNG. Set base URL `http://localhost:9990`. Enable "Search the web" in chats. (For page reading, add the SearXNG results to context or use a Firecrawl tool.) |
| **AnythingLLM** | "Web Search" provider = SearXNG, endpoint `http://localhost:9990`. |
| **Dify / Flowise / Langflow** | Add a SearXNG tool node and a Firecrawl HTTP-request tool node (URL `http://localhost:9991/v1/scrape`). |
| **n8n / Zapier-ish** | HTTP Request nodes to the two endpoints. |
| **LangChain / LlamaIndex** | Use a `RequestsToolkit` / custom tool that GETs/POSTs the two URLs. |

---

## Configuration reference

All runtime config lives in **`.env`** in your install folder (generated by the
installer; documented in `.env.example`). Edit it, then run `Update.bat` /
`./update.sh` to apply.

| Variable | Default | Meaning |
|----------|---------|---------|
| `SEARXNG_PORT` | `9990` | Host port for the SearXNG UI + JSON API. |
| `FIRECRAWL_PORT` | `9991` | Host port for the Firecrawl API. |
| `SEARXNG_SECRET` | *(random)* | SearXNG session secret — also injected into `config/searxng/settings.yml`. |
| `LOCAL_SEARCH_ENGINE` | *(set by the installer)* | `podman` or `docker`: the container engine `run.sh` / `stop.sh` / `update.sh` / `uninstall.sh` and the skill use. Without it: Podman if installed, else Docker. An environment variable of the same name overrides it. |
| `SEARXNG_MOUNT_OPTS` | *(empty; `,z` on SELinux hosts)* | Extra bind-mount options for SearXNG's `config/searxng` folder. `,z` relabels it so the container can read it on Fedora/RHEL; without that, SearXNG restart-loops with `Permission denied`. |
| `LOCAL_SEARCH_PAUSE` *(environment)* | `auto` | `auto`: the Linux/macOS scripts wait for a key press before closing when a launcher (file manager, desktop icon) opened their terminal window; `0` never waits, `1` always waits. |
| `SEARXNG_FORCE_OWNERSHIP` | `true` *(`false` on rootless Podman)* | Whether SearXNG's entrypoint re-owns the mounted config folder. `false` keeps the files yours under rootless Podman. |
| `BULL_AUTH_KEY` | *(random)* | Protects the (disabled-by-default) Firecrawl queue admin UI. |
| `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PASSWORD` | `firecrawl` / `firecrawl` / *(random)* | Firecrawl job-state DB credentials. |
| `RABBITMQ_USER` / `RABBITMQ_PASSWORD` | `firecrawl` / *(random)* | Firecrawl message-broker credentials. |
| `COMPOSE_PROFILES` | `playwright` | Which browser engine actually starts: `playwright` or `browserless` (installer Step 4). |
| `PLAYWRIGHT_MICROSERVICE_URL` | `http://playwright-service:3000/scrape` | Firecrawl's URL for its browser engine — must match `COMPOSE_PROFILES` (`http://browserless:3000/scrape` when that's `browserless`). |
| `BROWSERLESS_TOKEN` | *(random)* | Auth token for the Browserless service. Only used when `COMPOSE_PROFILES=browserless`; harmless if unused. |
| `LOGGING_LEVEL` | `info` | Firecrawl log verbosity (`debug`/`info`/`warn`/`error`). |
| `OPENAI_BASE_URL` | *(unset)* | OpenAI-compatible LLM endpoint for `/v1/extract` + summaries. For a same-host server use `http://host.docker.internal:<port>/v1`. |
| `OPENAI_API_KEY` | *(unset)* | Any non-empty string (most local servers ignore it). |
| `MODEL_NAME` | *(unset)* | The model id to use. |
| `OLLAMA_BASE_URL` | *(unset)* | Use instead of `OPENAI_*` for an Ollama backend. |

SearXNG behaviour (engines, formats, limiter) is tuned in
`config/searxng/settings.yml`. The defaults enable JSON output and disable the
bot limiter. To add/remove engines, edit that file and run `Update.bat` /
`./update.sh` (the container reads it at start).

The local-web-search skill needs no configuration: it reads the same `.env` at
runtime. The only extra file it uses is `install-dir.txt` (written by the
installer next to the skill's `SKILL.md`), which records the install folder so
the skill can start the stack even from a non-default location. To point the
skill at a different folder, set the `LOCAL_SEARCH_DIR` environment variable.

---

## Troubleshooting

**SearXNG restart-loops with `chown: /etc/searxng: Permission denied`, `cp: can't stat '/etc/searxng/settings.yml'`, `"/etc/searxng/settings.yml" is not a valid file, exiting...` (Fedora / RHEL).**
SELinux is blocking the container from reading the bind-mounted `config/searxng`
folder. The installer fixes this by writing `SEARXNG_MOUNT_OPTS=,z` to `.env`
(the compose file appends it to the mount). Check with `grep SEARXNG .env` and
`getenforce`, then run `./run.sh`. If you set the stack up with an older
installer, re-run the current one. On a filesystem that cannot be relabelled
(NFS, FAT/NTFS), install to a local ext4/xfs/btrfs folder instead.
If you start SearXNG by hand rather than through this stack, add `:z` to the
`-v` option, e.g. `-v ./config/searxng:/etc/searxng:z`.

**Searches are empty and SearXNG's log says `Failed to connect to ... over proxy 127.0.0.1 after 0 ms`.**
Podman copies the proxy variables of the shell that started it (`http_proxy`,
`https_proxy`, …) into every container — Docker does not. A value like
`http://127.0.0.1:7890` (typical with a local proxy/VPN tool) points at the
*container itself* there, so every outgoing request fails instantly. The
installer, `run.sh` and `update.sh` look at what the containers actually received
and, if a proxy variable points at `localhost`/`127.x`/`::1`, blank exactly those
variables through a generated `docker-compose.override.yml`. Proxies that point at
a real host (corporate, LAN) are left alone. To stop inheriting them at all, run
`unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY` before
`./run.sh`.

**SearXNG logs `WARNING "/etc/searxng" directory is not owned by "searxng:searxng"`.**
Harmless and expected with rootless Podman: the installer sets
`SEARXNG_FORCE_OWNERSHIP=false` so SearXNG does not re-own your config folder
(which would lock *you* out of editing it). SearXNG reads the files fine.

**The installer window closes immediately when I start it from the file manager.**
It now waits for a key press before closing whenever a launcher (not an
interactive shell) opened the terminal, so the output stays readable — also for `run.sh`,
`stop.sh`, `update.sh` and `uninstall.sh`. `LOCAL_SEARCH_PAUSE=0` turns it off.

**`podman compose` fails with "Cannot connect to the Docker daemon ... podman.sock".**
The Compose v2 provider talks to Podman's API socket. The installer tries to
start it; if that is not possible (no systemd), run
`systemctl --user enable --now podman.socket` (rootful: `sudo systemctl enable --now podman.socket`).

**"No compose provider was found for Podman".**
Install one: `sudo dnf install docker-compose` (or `podman-compose`;
Debian/Ubuntu: `sudo apt install docker-compose-v2`).

**Both Podman and Docker are installed and I want Docker.**
`LOCAL_SEARCH_ENGINE=docker ./install-local-search.sh` — it is recorded in
`.env`, so the other scripts follow. (Podman is used only when you do not choose.)

**The installer says the container engine "did not come online".**
The installer launches Docker Desktop / the docker service when the engine is
down, then waits up to 5 minutes (override with the `LOCAL_SEARCH_DOCKER_TIMEOUT`
env var, in seconds). If it times out, start Docker yourself, wait until it
reports "running", and re-run the installer — anything it already wrote is
safely overwritten.

**`docker compose up` fails with a port already in use.**
Re-run the installer and pick different ports, or stop whatever's using 9990/9991.

**SearXNG returns `429 Too Many Requests` or blocks requests.**
You're hitting an external engine's rate limit (not SearXNG itself). Wait a
minute, or in `config/searxng/settings.yml` remove the offending engine under
`engines:`. The internal limiter is already disabled for local use.

**`/v1/extract` returns an error / "model not configured".**
You haven't connected an LLM — see [section D](#d-connect-an-llm-lm-studio-etc).
`/v1/scrape`, `/v1/crawl`, `/v1/map`, `/v1/search` work without one.

**Firecrawl can't reach your LM Studio.**
From inside the Firecrawl container your host is `host.docker.internal`, **not**
`localhost`. Make sure (a) LM Studio has **"Serve on local network"** enabled,
and (b) `.env` has `OPENAI_BASE_URL=http://host.docker.internal:1234/v1`
(the installer does this conversion automatically). Test from the host first:
`curl http://localhost:1234/v1/models`.

**The local-web-search skill can't find the install folder.**
The skill looks for the compose folder via (1) the `LOCAL_SEARCH_DIR` env var,
(2) the compose labels on the running containers, (3) the `install-dir.txt`
hint the installer wrote next to the skill, and (4) `~/local-search`. If you
moved the install folder, re-run the installer or `Update.bat` / `./update.sh`
to refresh the hint — or export `LOCAL_SEARCH_DIR=/path/to/local-search`.

**The agent doesn't see the skill after install.**
Skills are usually scanned at agent startup — restart the agent. Also check the
skill actually landed at `~/.agents/skills/local-web-search/SKILL.md` (the installer
prints where it put it).

**First `docker compose pull` is slow / hits a GHCR 401.**
The Firecrawl images are public, but rate-limited. Authenticate:
`echo "$GITHUB_PAT" | docker login ghcr.io -u YOUR_GH_USER --password-stdin`
(token needs `read:packages`), then re-run `Update.bat` / `./update.sh`.

**Containers keep restarting.**
Check logs: `docker compose logs firecrawl` (or `searxng`). The most common
cause is a missing/empty `.env` value (e.g. `RABBITMQ_PASSWORD`). Re-run the
installer to regenerate a clean `.env`.

**SearXNG UI loads but `/search?format=json` returns HTML.**
The JSON format isn't enabled. Your `config/searxng/settings.yml` must contain
`search: formats: [html, json]` (the shipped config does). Restart with
`Update.bat` / `./update.sh` after editing.

**Reset everything to defaults.**
Run `Uninstall.bat` / `./uninstall.sh` (deletes volumes + data + the skill),
then run the installer again.

---

## Updating & uninstalling

- **Update images & apply config changes & re-sync the skill:** `Update.bat` /
  `./update.sh` (`docker compose pull && docker compose up -d`, then re-copy
  `local-web-search` into `~/.agents/skills/`). Data is preserved.
- **Update the SearXNG `settings.yml` / `docker-compose.yml` template:** re-run
  the installer — it copies the latest template over, refreshes the
  `local-web-search` skill, and backs up your existing `.env` to `.env.bak.<timestamp>`.
- **Uninstall:** `Uninstall.bat` / `./uninstall.sh`. Removes containers + Docker
  volumes (all Firecrawl/SearXNG data) + the `local-web-search` skill from
  `~/.agents/skills/local-web-search`, then asks whether to delete the install folder.
  Pulled images remain; reclaim with `docker image prune -a`.

---

## Development: full dev rig (rebuilding everything)

The `full-dev-rig/` folder holds two self-contained packers —
`local-search-rig.bat` (Windows) and `local-search-rig.sh` (Linux/macOS) —
that unpack the complete build/test environment in one shot: the
local-search source tree, `gen_installers.py` / `gen_rig.py`, every test
script, and `BUILD.md`.

1. **Unpack the rig** into a fresh folder (default:
   `<rig folder>\local-search-dev`):

   ```bat
   full-dev-rig\local-search-rig.bat
   ```

   ```sh
   ./full-dev-rig/local-search-rig.sh
   ```

   Answers: target folder (Enter = default), `y` = build right away,
   `y` = confirm. Unpacking runs `gen_installers.py` in the target folder
   when you answered `y`.

2. **Regenerate everything** inside the unpacked folder:

   ```sh
   python gen_installers.py   # rebuild install-local-search.bat/.sh
   python gen_rig.py          # rebuild the two packers byte-for-byte
   ```

   Fresh installers are written to `<target>\local-search\`, and fresh
   packers replace the unpacked `local-search-rig.*` copies. `BUILD.md`
   (inside the unpacked folder) documents the test scripts
   (`test_b64.py`, `test_rig.py`, `e2e_test.sh`, ...).

Note: the packers embed the source tree **as of when they were
generated**. Make source edits first, or copy the edited files into the
unpacked `local-search/` folder, before running the generators.

## Security notes

- This stack is designed for **local / trusted-network use**. Firecrawl's API is
  **unauthenticated** (`USE_DB_AUTHENTICATION=false`) so your models can call it
  without a key. **Do not expose ports 9990/9991 to the public internet.**
- All credentials (`SEARXNG_SECRET`, `BULL_AUTH_KEY`, `POSTGRES_PASSWORD`,
  `RABBITMQ_PASSWORD`, `BROWSERLESS_TOKEN`) are generated as 256-bit random hex
  at install time and stored only in your local `.env`.
- SearXNG's bot limiter is disabled and JSON output is enabled so models can
  query it — this is intentional for local use. On a public instance you'd want
  the limiter back on.
- Your search queries and scraped page contents never leave your machine
  (except the outbound fetches SearXNG/Firecrawl make to the public web, which
  is the whole point).

---

## Credits & licenses

This project is licensed under the **MPL-2.0** license — see [LICENSE](LICENSE)
(it covers the bundled [local-web-search](local-web-search) skill too).

- [**SearXNG**](https://github.com/searxng/searxng) — AGPL-3.0, privacy-respecting metasearch engine.
- [**Firecrawl**](https://github.com/firecrawl/firecrawl) — AGPL-3.0, the context API for web scraping/crawling/search.
- [**Firecrawl MCP server**](https://github.com/firecrawl/firecrawl-mcp-server) — MIT.
- The upstream projects retain their own licenses — please respect them.
  Nothing from them is bundled in this repository; the installer only pulls
  their official container images at install time.

---

<sub>Built so any local model — in LM Studio or otherwise — can search and read
the web without a paid API key. Contributions welcome.</sub>
EOF_README_MD
fi

# --- LICENSE ---
if [ -f "$SRC/LICENSE" ]; then
  cp "$SRC/LICENSE" "$TARGET/LICENSE"
else
  say "  [embedded] LICENSE  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/LICENSE" <<'EOF_LICENSE'
Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.2. "Contributor Version"
    means the combination of the Contributions of others (if any) used
    by a Contributor and that particular Contributor's Contribution.

1.3. "Contribution"
    means Covered Software of a particular Contributor.

1.4. "Covered Software"
    means Source Code Form to which the initial Contributor has attached
    the notice in Exhibit A, the Executable Form of such Source Code
    Form, and Modifications of such Source Code Form, in each case
    including portions thereof.

1.5. "Incompatible With Secondary Licenses"
    means

    (a) that the initial Contributor has attached the notice described
        in Exhibit B to the Covered Software; or

    (b) that the Covered Software was made available under the terms of
        version 1.1 or earlier of the License, but not also under the
        terms of a Secondary License.

1.6. "Executable Form"
    means any form of the work other than Source Code Form.

1.7. "Larger Work"
    means a work that combines Covered Software with other material, in
    a separate file or files, that is not Covered Software.

1.8. "License"
    means this document.

1.9. "Licensable"
    means having the right to grant, to the maximum extent possible,
    whether at the time of the initial grant or subsequently, any and
    all of the rights conveyed by this License.

1.10. "Modifications"
    means any of the following:

    (a) any file in Source Code Form that results from an addition to,
        deletion from, or modification of the contents of Covered
        Software; or

    (b) any new file in Source Code Form that contains any Covered
        Software.

1.11. "Patent Claims" of a Contributor
    means any patent claim(s), including without limitation, method,
    process, and apparatus claims, in any patent Licensable by such
    Contributor that would be infringed, but for the grant of the
    License, by the making, using, selling, offering for sale, having
    made, import, or transfer of either its Contributions or its
    Contributor Version.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.

1.13. "Source Code Form"
    means the form of the work preferred for making modifications.

1.14. "You" (or "Your")
    means an individual or a legal entity exercising rights under this
    License. For legal entities, "You" includes any entity that
    controls, is controlled by, or is under common control with You. For
    purposes of this definition, "control" means (a) the power, direct
    or indirect, to cause the direction or management of such entity,
    whether by contract or otherwise, or (b) ownership of more than
    fifty percent (50%) of the outstanding shares or beneficial
    ownership of such entity.

2. License Grants and Conditions
--------------------------------

2.1. Grants

Each Contributor hereby grants You a world-wide, royalty-free,
non-exclusive license:

(a) under intellectual property rights (other than patent or trademark)
    Licensable by such Contributor to use, reproduce, make available,
    modify, display, perform, distribute, and otherwise exploit its
    Contributions, either on an unmodified basis, with Modifications, or
    as part of a Larger Work; and

(b) under Patent Claims of such Contributor to make, use, sell, offer
    for sale, have made, import, and otherwise transfer either its
    Contributions or its Contributor Version.

2.2. Effective Date

The licenses granted in Section 2.1 with respect to any Contribution
become effective for each Contribution on the date the Contributor first
distributes such Contribution.

2.3. Limitations on Grant Scope

The licenses granted in this Section 2 are the only rights granted under
this License. No additional rights or licenses will be implied from the
distribution or licensing of Covered Software under this License.
Notwithstanding Section 2.1(b) above, no patent license is granted by a
Contributor:

(a) for any code that a Contributor has removed from Covered Software;
    or

(b) for infringements caused by: (i) Your and any other third party's
    modifications of Covered Software, or (ii) the combination of its
    Contributions with other software (except as part of its Contributor
    Version); or

(c) under Patent Claims infringed by Covered Software in the absence of
    its Contributions.

This License does not grant any rights in the trademarks, service marks,
or logos of any Contributor (except as may be necessary to comply with
the notice requirements in Section 3.4).

2.4. Subsequent Licenses

No Contributor makes additional grants as a result of Your choice to
distribute the Covered Software under a subsequent version of this
License (see Section 10.2) or under the terms of a Secondary License (if
permitted under the terms of Section 3.3).

2.5. Representation

Each Contributor represents that the Contributor believes its
Contributions are its original creation(s) or it has sufficient rights
to grant the rights to its Contributions conveyed by this License.

2.6. Fair Use

This License is not intended to limit any rights You have under
applicable copyright doctrines of fair use, fair dealing, or other
equivalents.

2.7. Conditions

Sections 3.1, 3.2, 3.3, and 3.4 are conditions of the licenses granted
in Section 2.1.

3. Responsibilities
-------------------

3.1. Distribution of Source Form

All distribution of Covered Software in Source Code Form, including any
Modifications that You create or to which You contribute, must be under
the terms of this License. You must inform recipients that the Source
Code Form of the Covered Software is governed by the terms of this
License, and how they can obtain a copy of this License. You may not
attempt to alter or restrict the recipients' rights in the Source Code
Form.

3.2. Distribution of Executable Form

If You distribute Covered Software in Executable Form then:

(a) such Covered Software must also be made available in Source Code
    Form, as described in Section 3.1, and You must inform recipients of
    the Executable Form how they can obtain a copy of such Source Code
    Form by reasonable means in a timely manner, at a charge no more
    than the cost of distribution to the recipient; and

(b) You may distribute such Executable Form under the terms of this
    License, or sublicense it under different terms, provided that the
    license for the Executable Form does not attempt to limit or alter
    the recipients' rights in the Source Code Form under this License.

3.3. Distribution of a Larger Work

You may create and distribute a Larger Work under terms of Your choice,
provided that You also comply with the requirements of this License for
the Covered Software. If the Larger Work is a combination of Covered
Software with a work governed by one or more Secondary Licenses, and the
Covered Software is not Incompatible With Secondary Licenses, this
License permits You to additionally distribute such Covered Software
under the terms of such Secondary License(s), so that the recipient of
the Larger Work may, at their option, further distribute the Covered
Software under the terms of either this License or such Secondary
License(s).

3.4. Notices

You may not remove or alter the substance of any license notices
(including copyright notices, patent notices, disclaimers of warranty,
or limitations of liability) contained within the Source Code Form of
the Covered Software, except that You may alter any license notices to
the extent required to remedy known factual inaccuracies.

3.5. Application of Additional Terms

You may choose to offer, and to charge a fee for, warranty, support,
indemnity or liability obligations to one or more recipients of Covered
Software. However, You may do so only on Your own behalf, and not on
behalf of any Contributor. You must make it absolutely clear that any
such warranty, support, indemnity, or liability obligation is offered by
You alone, and You hereby agree to indemnify every Contributor for any
liability incurred by such Contributor as a result of warranty, support,
indemnity or liability terms You offer. You may include additional
disclaimers of warranty and limitations of liability specific to any
jurisdiction.

4. Inability to Comply Due to Statute or Regulation
---------------------------------------------------

If it is impossible for You to comply with any of the terms of this
License with respect to some or all of the Covered Software due to
statute, judicial order, or regulation then You must: (a) comply with
the terms of this License to the maximum extent possible; and (b)
describe the limitations and the code they affect. Such description must
be placed in a text file included with all distributions of the Covered
Software under this License. Except to the extent prohibited by statute
or regulation, such description must be sufficiently detailed for a
recipient of ordinary skill to be able to understand it.

5. Termination
--------------

5.1. The rights granted under this License will terminate automatically
if You fail to comply with any of its terms. However, if You become
compliant, then the rights granted under this License from a particular
Contributor are reinstated (a) provisionally, unless and until such
Contributor explicitly and finally terminates Your grants, and (b) on an
ongoing basis, if such Contributor fails to notify You of the
non-compliance by some reasonable means prior to 60 days after You have
come back into compliance. Moreover, Your grants from a particular
Contributor are reinstated on an ongoing basis if such Contributor
notifies You of the non-compliance by some reasonable means, this is the
first time You have received notice of non-compliance with this License
from such Contributor, and You become compliant prior to 30 days after
Your receipt of the notice.

5.2. If You initiate litigation against any entity by asserting a patent
infringement claim (excluding declaratory judgment actions,
counter-claims, and cross-claims) alleging that a Contributor Version
directly or indirectly infringes any patent, then the rights granted to
You by any and all Contributors for the Covered Software under Section
2.1 of this License shall terminate.

5.3. In the event of termination under Sections 5.1 or 5.2 above, all
end user license agreements (excluding distributors and resellers) which
have been validly granted by You or Your distributors under this License
prior to termination shall survive termination.

************************************************************************
*                                                                      *
*  6. Disclaimer of Warranty                                           *
*  -------------------------                                           *
*                                                                      *
*  Covered Software is provided under this License on an "as is"       *
*  basis, without warranty of any kind, either expressed, implied, or  *
*  statutory, including, without limitation, warranties that the       *
*  Covered Software is free of defects, merchantable, fit for a        *
*  particular purpose or non-infringing. The entire risk as to the     *
*  quality and performance of the Covered Software is with You.        *
*  Should any Covered Software prove defective in any respect, You     *
*  (not any Contributor) assume the cost of any necessary servicing,   *
*  repair, or correction. This disclaimer of warranty constitutes an   *
*  essential part of this License. No use of any Covered Software is   *
*  authorized under this License except under this disclaimer.         *
*                                                                      *
************************************************************************

************************************************************************
*                                                                      *
*  7. Limitation of Liability                                          *
*  --------------------------                                          *
*                                                                      *
*  Under no circumstances and under no legal theory, whether tort      *
*  (including negligence), contract, or otherwise, shall any           *
*  Contributor, or anyone who distributes Covered Software as          *
*  permitted above, be liable to You for any direct, indirect,         *
*  special, incidental, or consequential damages of any character      *
*  including, without limitation, damages for lost profits, loss of    *
*  goodwill, work stoppage, computer failure or malfunction, or any    *
*  and all other commercial damages or losses, even if such party      *
*  shall have been informed of the possibility of such damages. This   *
*  limitation of liability shall not apply to liability for death or   *
*  personal injury resulting from such party's negligence to the       *
*  extent applicable law prohibits such limitation. Some               *
*  jurisdictions do not allow the exclusion or limitation of           *
*  incidental or consequential damages, so this exclusion and          *
*  limitation may not apply to You.                                    *
*                                                                      *
************************************************************************

8. Litigation
-------------

Any litigation relating to this License may be brought only in the
courts of a jurisdiction where the defendant maintains its principal
place of business and such litigation shall be governed by laws of that
jurisdiction, without reference to its conflict-of-law provisions.
Nothing in this Section shall prevent a party's ability to bring
cross-claims or counter-claims.

9. Miscellaneous
----------------

This License represents the complete agreement concerning the subject
matter hereof. If any provision of this License is held to be
unenforceable, such provision shall be reformed only to the extent
necessary to make it enforceable. Any law or regulation which provides
that the language of a contract shall be construed against the drafter
shall not be used to construe this License against a Contributor.

10. Versions of the License
---------------------------

10.1. New Versions

Mozilla Foundation is the license steward. Except as provided in Section
10.3, no one other than the license steward has the right to modify or
publish new versions of this License. Each version will be given a
distinguishing version number.

10.2. Effect of New Versions

You may distribute the Covered Software under the terms of the version
of the License under which You originally received the Covered Software,
or under the terms of any subsequent version published by the license
steward.

10.3. Modified Versions

If you create software not governed by this License, and you want to
create a new license for such software, you may create and use a
modified version of this License if you rename the license and remove
any references to the name of the license steward (except to note that
such modified license differs from this License).

10.4. Distributing Source Code Form that is Incompatible With Secondary
Licenses

If You choose to distribute Source Code Form that is Incompatible With
Secondary Licenses under the terms of this version of the License, the
notice described in Exhibit B of this License must be attached.

Exhibit A - Source Code Form License Notice
-------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at https://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular
file, then You may include the notice in a location (such as a LICENSE
file in a relevant directory) where a recipient would be likely to look
for such a notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice
---------------------------------------------------------

  This Source Code Form is "Incompatible With Secondary Licenses", as
  defined by the Mozilla Public License, v. 2.0.
EOF_LICENSE
fi

# --- .gitignore ---
if [ -f "$SRC/.gitignore" ]; then
  cp "$SRC/.gitignore" "$TARGET/.gitignore"
else
  say "  [embedded] .gitignore  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/.gitignore" <<'EOF__GITIGNORE'
# ---- Generated at install time (contains your ports and secrets) ----
.env
.env.bak.*

# ---- Written by the installer into installed skill copies ----
# (the source copy in the repo must stay clean; the installer records the
#  install path here when it copies the skill to ~/.agents/skills/local-web)
local-web/install-dir.txt

# ---- Python bytecode (skill scripts) ----
__pycache__/
*.pyc

# ---- OS junk ----
.DS_Store
Thumbs.db
desktop.ini

# ---- Logs ----
*.log
EOF__GITIGNORE
fi

# --- .gitattributes ---
if [ -f "$SRC/.gitattributes" ]; then
  cp "$SRC/.gitattributes" "$TARGET/.gitattributes"
else
  say "  [embedded] .gitattributes  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/.gitattributes" <<'EOF__GITATTRIBUTES'
# Normalize text files in the repo; keep platform-native line endings on checkout
* text=auto

# Windows batch files must keep CRLF working copies
*.bat text eol=crlf
*.cmd text eol=crlf
*.ps1 text eol=crlf

# Unix scripts must stay LF
*.sh text eol=lf
*.py text eol=lf
*.yml text eol=lf
*.yaml text eol=lf

# Docs
*.md text
LICENSE text
EOF__GITATTRIBUTES
fi

# --- Run.bat ---
if [ -f "$SRC/Run.bat" ]; then
  cp "$SRC/Run.bat" "$TARGET/Run.bat"
else
  say "  [embedded] Run.bat  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/Run.bat" <<'EOF_RUN_BAT'
@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Run

cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is not installed or not on PATH. Install Docker Desktop first.
  pause
  exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker engine is not running. Start Docker Desktop first.
  pause
  exit /b 1
)

if not exist ".env" (
  echo [ERROR] No .env file found in this folder.
  echo   Run install-local-search.bat first to create the configuration.
  pause
  exit /b 1
)

echo Starting Local Search (Firecrawl + SearXNG)...
docker compose up -d
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to start. See messages above.
  pause
  exit /b 1
)

echo.
echo Local Search is running:
echo   SearXNG:   http://localhost:9990      ^(change in .env^)
echo   Firecrawl: http://localhost:9991      ^(change in .env^)
echo.
echo Open the SearXNG UI in your browser, or query the JSON API from your models.
echo Use Stop.bat to stop the stack.
echo.
pause
exit /b 0
EOF_RUN_BAT
fi

# --- Stop.bat ---
if [ -f "$SRC/Stop.bat" ]; then
  cp "$SRC/Stop.bat" "$TARGET/Stop.bat"
else
  say "  [embedded] Stop.bat  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/Stop.bat" <<'EOF_STOP_BAT'
@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Stop

cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is not installed or not on PATH.
  pause
  exit /b 1
)

if not exist ".env" (
  echo [ERROR] No .env file found in this folder. Nothing to stop.
  pause
  exit /b 1
)

echo Stopping Local Search containers (data is preserved)...
docker compose down
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to stop. See messages above.
  pause
  exit /b 1
)

echo.
echo Local Search stopped. Data is preserved in Docker volumes.
echo Run Run.bat to start it again.
echo.
pause
exit /b 0
EOF_STOP_BAT
fi

# --- Update.bat ---
if [ -f "$SRC/Update.bat" ]; then
  cp "$SRC/Update.bat" "$TARGET/Update.bat"
else
  say "  [embedded] Update.bat  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/Update.bat" <<'EOF_UPDATE_BAT'
@echo off
setlocal enableDelayedExpansion
chcp 65001 >nul
title Local Search - Update

cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is not installed or not on PATH.
  pause
  exit /b 1
)
docker info >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker engine is not running. Start Docker Desktop first.
  pause
  exit /b 1
)

if not exist ".env" (
  echo [ERROR] No .env file found in this folder.
  echo   Run install-local-search.bat first to create the configuration.
  pause
  exit /b 1
)

echo Updating Local Search...
echo.
echo [1/3] Pulling latest images...
docker compose pull
if errorlevel 1 (
  echo.
  echo [WARNING] Some images failed to pull. Continuing with what is available.
)

echo.
echo [2/3] Recreating containers with updated images (data is preserved)...
docker compose up -d
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to recreate containers. See messages above.
  pause
  exit /b 1
)

echo.
echo [3/3] Refreshing the local-web-search agent skill...
if exist "%~dp0local-web-search\SKILL.md" (
  set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web-search"
  if exist "!SKILL_DIR!" rd /s /q "!SKILL_DIR!"
  if not exist "%USERPROFILE%\.agents\skills" mkdir "%USERPROFILE%\.agents\skills"
  xcopy /E /I /Y /Q "%~dp0local-web-search" "!SKILL_DIR!" >nul
  if errorlevel 1 (
    echo   [WARNING] Could not copy the skill to !SKILL_DIR!.
  ) else (
    > "!SKILL_DIR!\install-dir.txt" echo %~dp0
    echo   Skill refreshed at !SKILL_DIR!
  )
) else (
  echo   local-web-search skill source not found in this folder - skipping.
)

echo.
echo Update complete. Data volumes were preserved.
echo   - If you changed ports or LLM settings in .env, they are now applied.
echo   - The local-web-search skill was re-synced from this folder.
echo   - To update the SearXNG settings.yml or docker-compose.yml template,
echo     re-run install-local-search.bat (it backs up your current .env).
echo.
pause
exit /b 0
EOF_UPDATE_BAT
fi

# --- Uninstall.bat ---
if [ -f "$SRC/Uninstall.bat" ]; then
  cp "$SRC/Uninstall.bat" "$TARGET/Uninstall.bat"
else
  say "  [embedded] Uninstall.bat  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/Uninstall.bat" <<'EOF_UNINSTALL_BAT'
@echo off
setlocal enableDelayedExpansion
title Local Search - Uninstall
REM  Prompts run on a code page other than 65001: while the console is on 65001
REM  (UTF-8), set /p returns an empty line for redirected or piped stdin, so
REM  scripted answers are lost. The code page the console started on is used, or
REM  437 when it is already 65001 (chcp persists after a script ends). UTF-8 is
REM  enabled after the last prompt.
set "LS_PROMPT_CP=437"
for /f "tokens=2 delims=:" %%c in ('chcp') do for /f %%n in ("%%c") do set "LS_PROMPT_CP=%%n"
if "!LS_PROMPT_CP!"=="65001" set "LS_PROMPT_CP=437"
chcp !LS_PROMPT_CP! >nul 2>&1

cd /d "%~dp0"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker is not installed or not on PATH.
  echo   You can manually delete this folder to remove the files.
  pause
  exit /b 1
)

if not exist ".env" (
  echo [ERROR] No .env file found in this folder. Nothing to uninstall.
  pause
  exit /b 1
)

echo ============================================================
echo   Uninstall Local Search
echo ============================================================
echo This will:
echo   1. Stop and remove all Local Search containers.
echo   2. Remove the Docker VOLUMES (Firecrawl job state, redis cache,
echo      rabbitmq/postgres data). This deletes all stored data.
echo   3. Remove the local-web-search agent skill from
echo      %USERPROFILE%\.agents\skills\local-web-search
echo   4. (Optional) Delete the install folder and all its files.
echo.
echo   Pulled Docker images are NOT removed (use "docker image prune" to
echo   reclaim that disk space separately).
echo.
set "CONFIRM="
set /p CONFIRM="Continue with uninstall? [y/N]: "
if /i not "!CONFIRM!"=="y" ( echo Uninstall cancelled. & pause & exit /b 0 )
REM  All prompts are answered - safe to switch to UTF-8 for the output phase.
chcp 65001 >nul

echo.
echo Stopping and removing containers + volumes...
docker compose down -v --remove-orphans
if errorlevel 1 (
  echo.
  echo [WARNING] docker compose down reported errors.
  echo   You may need to remove leftover containers manually, e.g.:
  echo     docker rm -f local-search-firecrawl local-search-searxng
  echo     docker rm -f local-search-redis local-search-rabbitmq
  echo     docker rm -f local-search-postgres local-search-playwright local-search-browserless
)

echo.
echo Containers and volumes removed.
echo.
echo Removing the local-web-search agent skill...
set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web-search"
if exist "!SKILL_DIR!" (
  rd /s /q "!SKILL_DIR!"
  echo   Removed !SKILL_DIR!
) else (
  echo   Skill not found ^(already removed^) - nothing to do.
)
echo.
REM  The second prompt also needs a code page other than 65001 (see top of file).
chcp !LS_PROMPT_CP! >nul 2>&1
set "DELFILES="
set /p DELFILES="Also delete the install folder and ALL its files? [y/N]: "
if /i not "!DELFILES!"=="y" (
  echo.
  echo Uninstall finished. The folder was kept:
  echo   %CD%
  echo   You can delete it manually if you no longer need the scripts.
  echo.
  pause
  exit /b 0
)

cd /d "%USERPROFILE%"
echo Deleting install folder: %~dp0
rd /s /q "%~dp0"
echo.
echo Uninstall complete. Goodbye!
echo.
pause
exit /b 0
EOF_UNINSTALL_BAT
fi

# --- run.sh ---
if [ -f "$SRC/run.sh" ]; then
  cp "$SRC/run.sh" "$TARGET/run.sh"
else
  say "  [embedded] run.sh  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/run.sh" <<'EOF_RUN_SH'
#!/usr/bin/env bash
# Start the Local Search stack (Firecrawl + SearXNG).
# Uses Podman when it is installed, otherwise Docker (see engine.sh; override
# with LOCAL_SEARCH_ENGINE=podman|docker or the same line in .env).
set -u
cd "$(dirname "$0")" || exit 1

[ -f "./engine.sh" ] || {
  echo "[ERROR] engine.sh is missing from this folder. Re-run install-local-search.sh." >&2; exit 1; }
# shellcheck source=engine.sh
. ./engine.sh
ls_pause_on_exit          # keep a launcher-opened window open at the end
ls_require_engine running

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found in this folder. Run install-local-search.sh first." >&2
  exit 1
fi

echo "Starting Local Search (Firecrawl + SearXNG) with $ENGINE_NAME..."
$DC up -d || { echo "[ERROR] Failed to start." >&2; exit 1; }

SEARXNG_PORT="$(ls_env_value .env SEARXNG_PORT)"; SEARXNG_PORT="${SEARXNG_PORT:-9990}"
FIRECRAWL_PORT="$(ls_env_value .env FIRECRAWL_PORT)"; FIRECRAWL_PORT="${FIRECRAWL_PORT:-9991}"
echo
ls_verify_searxng "$SEARXNG_PORT" || exit 1
ls_fix_container_proxy "$SEARXNG_PORT" || exit 1

echo
echo "Local Search is running."
echo "  SearXNG:   http://localhost:${SEARXNG_PORT}"
echo "  Firecrawl: http://localhost:${FIRECRAWL_PORT}"
echo "Run ./stop.sh to stop the stack."
EOF_RUN_SH
fi

# --- stop.sh ---
if [ -f "$SRC/stop.sh" ]; then
  cp "$SRC/stop.sh" "$TARGET/stop.sh"
else
  say "  [embedded] stop.sh  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/stop.sh" <<'EOF_STOP_SH'
#!/usr/bin/env bash
# Stop the Local Search stack (containers removed, data preserved).
set -u
cd "$(dirname "$0")" || exit 1

[ -f "./engine.sh" ] || {
  echo "[ERROR] engine.sh is missing from this folder. Re-run install-local-search.sh." >&2; exit 1; }
# shellcheck source=engine.sh
. ./engine.sh
ls_pause_on_exit
ls_require_engine

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found. Nothing to stop." >&2; exit 1
fi

echo "Stopping Local Search containers (data is preserved)..."
$DC down || { echo "[ERROR] Failed to stop." >&2; exit 1; }

echo
echo "Local Search stopped. Data is preserved in $ENGINE_NAME volumes."
echo "Run ./run.sh to start it again."
EOF_STOP_SH
fi

# --- update.sh ---
if [ -f "$SRC/update.sh" ]; then
  cp "$SRC/update.sh" "$TARGET/update.sh"
else
  say "  [embedded] update.sh  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/update.sh" <<'EOF_UPDATE_SH'
#!/usr/bin/env bash
# Update the Local Search stack: pull latest images, recreate containers,
# and re-sync the local-web-search agent skill. Data volumes are preserved. Edits
# to .env (ports, LLM) are also applied.
set -u
cd "$(dirname "$0")" || exit 1

[ -f "./engine.sh" ] || {
  echo "[ERROR] engine.sh is missing from this folder. Re-run install-local-search.sh." >&2; exit 1; }
# shellcheck source=engine.sh
. ./engine.sh
ls_pause_on_exit
ls_require_engine running

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found. Run install-local-search.sh first." >&2
  exit 1
fi

echo "Updating Local Search (using $ENGINE_NAME)..."
echo
echo "[1/3] Pulling latest images..."
$DC pull || echo "[WARNING] Some images failed to pull. Continuing."

echo
echo "[2/3] Recreating containers with updated images (data is preserved)..."
$DC up -d || { echo "[ERROR] Failed to recreate containers." >&2; exit 1; }
SEARXNG_PORT="$(ls_env_value .env SEARXNG_PORT)"; SEARXNG_PORT="${SEARXNG_PORT:-9990}"
ls_verify_searxng "$SEARXNG_PORT"; VERIFY_RC=$?
if [ "$VERIFY_RC" -eq 0 ]; then ls_fix_container_proxy "$SEARXNG_PORT"; VERIFY_RC=$?; fi

echo
echo "[3/3] Refreshing the local-web-search agent skill..."
if [ -f "./local-web-search/SKILL.md" ]; then
  SKILL_DIR="$HOME/.agents/skills/local-web-search"
  rm -rf "$SKILL_DIR"
  mkdir -p "$HOME/.agents/skills"
  if cp -r ./local-web-search "$SKILL_DIR"; then
    printf '%s\n' "$(pwd)" > "$SKILL_DIR/install-dir.txt"
    echo "  Skill refreshed at $SKILL_DIR"
  else
    echo "  [WARNING] Could not copy the skill to $SKILL_DIR."
  fi
else
  echo "  local-web-search skill source not found in this folder - skipping."
fi

echo
if [ "$VERIFY_RC" -ne 0 ]; then
  echo "Update finished, but SearXNG or the containers' proxy settings need attention - see the details above." >&2
  exit 1
fi
echo "Update complete. Data volumes were preserved."
echo "  - Port / LLM changes in .env are now applied."
echo "  - The local-web-search skill was re-synced from this folder."
echo "  - To update the SearXNG settings.yml or docker-compose.yml template,"
echo "    re-run install-local-search.sh (it backs up your current .env)."
EOF_UPDATE_SH
fi

# --- uninstall.sh ---
if [ -f "$SRC/uninstall.sh" ]; then
  cp "$SRC/uninstall.sh" "$TARGET/uninstall.sh"
else
  say "  [embedded] uninstall.sh  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/uninstall.sh" <<'EOF_UNINSTALL_SH'
#!/usr/bin/env bash
# Uninstall the Local Search stack.
#   - stops & removes containers
#   - removes container volumes (Firecrawl job state, redis, rabbitmq, postgres)
#   - removes the local-web-search agent skill (~/.agents/skills/local-web-search)
#   - optionally deletes the install folder
set -u
cd "$(dirname "$0")" || exit 1
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }  # bash-3.2 (macOS) safe

[ -f "./engine.sh" ] || {
  echo "[ERROR] engine.sh is missing from this folder. Re-run install-local-search.sh." >&2; exit 1; }
# shellcheck source=engine.sh
. ./engine.sh
ls_pause_on_exit
if ! ls_select_engine "./.env"; then
  echo "  You can delete this folder manually." >&2
  exit 1
fi
ls_select_compose || exit 1
ls_ensure_podman_socket || echo "  [!] Podman's API socket is not active - if compose fails, run: systemctl --user enable --now podman.socket"

if [ ! -f ".env" ]; then
  echo "[ERROR] No .env file found. Nothing to uninstall." >&2; exit 1
fi

cat <<'MSG'
============================================================
  Uninstall Local Search
============================================================
This will:
  1. Stop and remove all Local Search containers.
  2. Remove the container VOLUMES (Firecrawl job state, redis cache,
     rabbitmq/postgres data). This deletes all stored data.
  3. Remove the local-web-search agent skill from
     ~/.agents/skills/local-web-search
  4. (Optional) Delete the install folder and all its files.

  Pulled images are NOT removed (use 'podman image prune' or
  'docker image prune' to reclaim that disk space separately).
MSG
echo
printf "Continue with uninstall? [y/N]: "
read -r CONFIRM
if [ "$(lower "$CONFIRM")" != "y" ]; then echo "Uninstall cancelled."; exit 0; fi

echo
echo "Stopping and removing containers + volumes..."
$DC down -v --remove-orphans || echo "[WARNING] docker compose down reported errors."

echo
echo "Containers and volumes removed."
echo
echo "Removing the local-web-search agent skill..."
SKILL_DIR="$HOME/.agents/skills/local-web-search"
if [ -d "$SKILL_DIR" ]; then
  rm -rf "$SKILL_DIR"
  echo "  Removed $SKILL_DIR"
else
  echo "  Skill not found (already removed) - nothing to do."
fi
echo
printf "Also delete the install folder and ALL its files? [y/N]: "
read -r DELFILES
if [ "$(lower "$DELFILES")" != "y" ]; then
  echo
  echo "Uninstall finished. The folder was kept:"
  echo "  $(pwd)"
  echo "  You can delete it manually if you no longer need the scripts."
  exit 0
fi

TARGET="$(pwd)"
cd "$HOME"
echo "Deleting install folder: $TARGET"
rm -rf "$TARGET"
echo
echo "Uninstall complete. Goodbye!"
EOF_UNINSTALL_SH
fi

# --- engine.sh ---
if [ -f "$SRC/engine.sh" ]; then
  cp "$SRC/engine.sh" "$TARGET/engine.sh"
else
  say "  [embedded] engine.sh  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/engine.sh" <<'EOF_ENGINE_SH'
# =============================================================================
#  engine.sh - container-engine detection for the Local Search shell scripts
# =============================================================================
#  Sourced by run.sh / stop.sh / update.sh / uninstall.sh, and inlined verbatim
#  into install-local-search.sh by gen_installers.py - so there is exactly ONE
#  copy of this logic. It is a library: it is not meant to be run on its own.
#
#  Which engine is used (first match wins):
#    1. LOCAL_SEARCH_ENGINE=podman|docker in the environment   (forced)
#    2. LOCAL_SEARCH_ENGINE=podman|docker in the install folder's .env
#       (the installer records its choice there, so run.sh / update.sh keep
#        using the engine that created the containers)
#    3. auto-detect: Podman when it is installed, otherwise Docker
#       (if both are installed, Podman wins)
#
#  Functions (all bash 3.2 safe):
#    ls_select_engine [ENVFILE]  sets ENGINE (podman|docker), ENGINE_NAME, ENGINE_AUTO
#    ls_engine_running           0 when the selected engine answers
#    ls_start_engine             best-effort launch of a stopped engine
#    ls_fallback_engine          auto-picked Podman unusable + Docker running -> Docker
#    ls_engine_hint              prints "how to start it yourself" help
#    ls_select_compose           sets DC (e.g. "podman compose", "docker compose")
#    ls_ensure_podman_socket     starts Podman's API socket (needed by docker-compose)
#    ls_platform_env             sets LS_MOUNT_OPTS / LS_FORCE_OWNERSHIP for .env
#    ls_verify_searxng PORT      waits until SearXNG answers; diagnoses if it does not
#    ls_fix_container_proxy PORT  blanks loopback proxy variables the containers inherited from the shell
#    ls_pause_on_exit            keeps a launcher-opened terminal window open at the end
#    ls_require_engine [running] select + compose (+ running check); exits on failure
# =============================================================================

ls_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
ls_err()   { if type err >/dev/null 2>&1; then err "$1"; else printf '[ERROR] %s\n' "$1" >&2; fi; }
ls_say()   { if type say >/dev/null 2>&1; then say "$1"; else printf '%s\n' "$1"; fi; }
ls_ok()    { if type ok  >/dev/null 2>&1; then ok  "$1"; else printf '[OK] %s\n' "$1"; fi; }

# ls_env_value FILE KEY -> the last KEY=value line of FILE (quotes / CR stripped)
ls_env_value() {
  [ -f "$1" ] || return 0
  grep -E "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r"' | tr -d "'"
}

ls_install_hint() {
  ls_say ""
  ls_say "Install one of them, then re-run:"
  ls_say "  Podman (preferred when both are installed):"
  ls_say "    Fedora / RHEL:    sudo dnf install podman docker-compose"
  ls_say "    Debian / Ubuntu:  sudo apt install podman docker-compose-v2"
  ls_say "    macOS:            brew install podman docker-compose && podman machine init"
  ls_say "  Docker:"
  ls_say "    Linux:  https://docs.docker.com/engine/install/"
  ls_say "    macOS:  https://www.docker.com/products/docker-desktop/"
}

ls_select_engine() {
  local want="" src="" have_p=0 have_d=0
  ENGINE=""; ENGINE_NAME=""; ENGINE_AUTO=0
  command -v podman >/dev/null 2>&1 && have_p=1
  command -v docker >/dev/null 2>&1 && have_d=1

  want="$(ls_lower "${LOCAL_SEARCH_ENGINE:-}")"
  if [ -n "$want" ]; then
    src="LOCAL_SEARCH_ENGINE"
  elif [ -n "${1:-}" ]; then
    want="$(ls_lower "$(ls_env_value "$1" LOCAL_SEARCH_ENGINE)")"
    src=".env"
  fi
  case "$want" in
    ""|auto) want="" ;;
    podman|docker) ;;
    *) ls_err "$src must be 'podman' or 'docker' (got '$want')."; return 1 ;;
  esac

  if [ -n "$want" ]; then
    if [ "$want" = "podman" ] && [ "$have_p" = 1 ]; then ENGINE=podman; ENGINE_NAME=Podman; return 0; fi
    if [ "$want" = "docker" ] && [ "$have_d" = 1 ]; then ENGINE=docker; ENGINE_NAME=Docker; return 0; fi
    if [ "$src" = "LOCAL_SEARCH_ENGINE" ]; then
      ls_err "LOCAL_SEARCH_ENGINE=$want, but '$want' was not found on your PATH."
      return 1
    fi
    ls_say "  [!] .env asks for '$want', which is not installed - auto-detecting instead."
  fi

  ENGINE_AUTO=1
  if   [ "$have_p" = 1 ]; then ENGINE=podman; ENGINE_NAME=Podman
  elif [ "$have_d" = 1 ]; then ENGINE=docker; ENGINE_NAME=Docker
  else
    ls_err "Neither Podman nor Docker was found on your PATH."
    ls_install_hint
    return 1
  fi
  return 0
}

ls_engine_running() { "$ENGINE" info >/dev/null 2>&1; }

# Auto-picked Podman cannot run but Docker answers: use Docker (with a notice
# from the caller). Never overrides an explicit LOCAL_SEARCH_ENGINE / .env choice.
ls_fallback_engine() {
  [ "${ENGINE_AUTO:-0}" = 1 ] && [ "$ENGINE" = "podman" ] || return 1
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
  ENGINE=docker; ENGINE_NAME=Docker
  return 0
}

# Launch a stopped engine. Returns 0 when a start was issued (the caller waits
# for it with ls_engine_running), 1 when there is nothing it can start.
ls_start_engine() {
  local unit
  if [ "$ENGINE" = "podman" ]; then
    # Linux: rootless Podman has no daemon, so there is nothing to start.
    # macOS: Podman runs in a VM ("podman machine") that has to be started.
    if [ "$(uname)" = "Darwin" ]; then
      [ -n "$(podman machine list --format '{{.Name}}' 2>/dev/null)" ] || return 1
      ( podman machine start >/dev/null 2>&1 & )
      return 0
    fi
    return 1
  fi
  if [ "$(uname)" = "Darwin" ]; then
    # macOS: launch Docker Desktop if it is installed
    if command -v open >/dev/null 2>&1 \
       && { [ -d "/Applications/Docker.app" ] || [ -d "$HOME/Applications/Docker.app" ]; }; then
      open -a Docker >/dev/null 2>&1 && return 0
    fi
    return 1
  fi
  # Linux: systemd units (Docker Desktop uses docker-desktop, the classic
  # engine uses docker), then service(1). Non-interactive sudo only - an
  # installer never prompts for a password.
  if command -v systemctl >/dev/null 2>&1; then
    for unit in docker-desktop docker; do
      if systemctl start "$unit" >/dev/null 2>&1; then return 0; fi
      if command -v sudo >/dev/null 2>&1 \
         && sudo -n systemctl start "$unit" >/dev/null 2>&1; then
        return 0
      fi
    done
  fi
  if command -v service >/dev/null 2>&1; then
    if service docker start >/dev/null 2>&1; then return 0
    elif command -v sudo >/dev/null 2>&1 \
         && sudo -n service docker start >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

ls_engine_hint() {
  if [ "$ENGINE" = "podman" ]; then
    ls_say "  Run 'podman info' to see why Podman does not answer."
    ls_say "  (rootless Podman needs a normal login session and subuid/subgid entries)"
    ls_say "  macOS:  podman machine init && podman machine start"
  else
    ls_say "  Linux:  sudo systemctl start docker    (or launch Docker Desktop)"
    ls_say "          permission denied from docker? add yourself to the docker"
    ls_say "          group:  sudo usermod -aG docker ${USER:-youruser}  (log out and back in)"
    ls_say "  macOS:  open -a Docker"
  fi
}

ls_select_compose() {
  DC=""
  if [ "$ENGINE" = "podman" ]; then
    if podman compose version >/dev/null 2>&1; then DC="podman compose"
    elif command -v podman-compose >/dev/null 2>&1; then DC="podman-compose"
    else
      ls_err "No compose provider was found for Podman."
      ls_say "  Install one (Compose v2 'docker-compose' is the most compatible):"
      ls_say "    Fedora / RHEL:    sudo dnf install docker-compose     (or: podman-compose)"
      ls_say "    Debian / Ubuntu:  sudo apt install docker-compose-v2  (or: podman-compose)"
      ls_say "    macOS:            brew install docker-compose"
      return 1
    fi
    # 'podman compose' prints a provider banner on every call in newer Podman.
    export PODMAN_COMPOSE_WARNING_LOGS=false
  else
    if docker compose version >/dev/null 2>&1; then DC="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
    else
      ls_err "Docker Compose was not found. Install the 'docker compose' plugin (v2)."
      return 1
    fi
  fi
  return 0
}

# 'podman compose' normally hands over to docker-compose, which talks to
# Podman's API socket. On a fresh Fedora session that socket is not running, and
# docker-compose then fails with "Cannot connect to the Docker daemon". Start it
# when possible. Returns 0 when the socket exists afterwards. Never fatal: a
# compose provider that does not need the socket (podman-compose) works anyway.
ls_ensure_podman_socket() {
  [ "$ENGINE" = "podman" ] && [ "$DC" = "podman compose" ] || return 0
  [ "$(uname)" = "Linux" ] || return 0
  [ "$(podman info --format '{{.Host.RemoteSocket.Exists}}' 2>/dev/null)" = "true" ] && return 0
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
      systemctl --user start podman.socket >/dev/null 2>&1
    else
      systemctl start podman.socket >/dev/null 2>&1 \
        || { command -v sudo >/dev/null 2>&1 && sudo -n systemctl start podman.socket >/dev/null 2>&1; }
    fi
  fi
  [ "$(podman info --format '{{.Host.RemoteSocket.Exists}}' 2>/dev/null)" = "true" ]
}

ls_selinux_on() {
  [ "$(uname)" = "Linux" ] || return 1
  if command -v getenforce >/dev/null 2>&1; then
    case "$(getenforce 2>/dev/null)" in Enforcing|Permissive) return 0 ;; esac
    return 1
  fi
  [ -e /sys/fs/selinux/enforce ]
}

ls_podman_rootless() {
  [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]
}

# Decides the two SearXNG bind-mount settings that the installer writes to .env
# (they feed ${SEARXNG_MOUNT_OPTS} / ${SEARXNG_FORCE_OWNERSHIP} in the compose file):
#   LS_MOUNT_OPTS       ",z" on SELinux hosts (lets the container read the folder)
#   LS_FORCE_OWNERSHIP  "false" on rootless Podman (keeps the files yours), else "true"
ls_platform_env() {
  LS_MOUNT_OPTS=""; LS_FORCE_OWNERSHIP="true"
  if ls_selinux_on; then LS_MOUNT_OPTS=",z"; fi
  if [ "$ENGINE" = "podman" ] && ls_podman_rootless; then LS_FORCE_OWNERSHIP="false"; fi
  return 0
}

# ls_http_ok PORT -> 0 when something answers HTTP on localhost:PORT. A bare TCP
# connect is not enough: the engine publishes the port even while the container
# behind it is crash-looping.
ls_http_ok() {
  (
    exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
    printf 'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
    line=""
    IFS= read -r -t 3 line <&3 || exit 1
    case "$line" in HTTP/*) exit 0 ;; esac
    exit 1
  ) 2>/dev/null
}

# ls_verify_searxng PORT  (run from the install folder; needs $DC)
# Waits up to LOCAL_SEARCH_VERIFY_TIMEOUT seconds (default 90, 0 = skip). When
# SearXNG never answers it prints the container state + last log lines and, for
# permission errors, the SELinux fix. Returns 1 in that case.
ls_verify_searxng() {
  local port="$1" limit="${LOCAL_SEARCH_VERIFY_TIMEOUT:-90}" waited=0 logs=""
  [ "$limit" -gt 0 ] 2>/dev/null || return 0
  ls_say "Checking that SearXNG answers on port $port (up to ${limit}s)..."
  while :; do
    if ls_http_ok "$port"; then ls_ok "SearXNG is answering on port $port."; return 0; fi
    [ "$waited" -ge "$limit" ] && break
    sleep 3
    waited=$((waited + 3))
  done
  ls_err "SearXNG did not answer on port $port within ${limit}s."
  ls_say ""
  ls_say "  Container state:"
  $DC ps 2>&1 | sed 's/^/    /' | head -n 12
  logs="$($DC logs --tail 15 searxng 2>&1)"
  ls_say "  Last SearXNG log lines:"
  printf '%s\n' "$logs" | sed 's/^/    /'
  if printf '%s' "$logs" | grep -qi "permission denied"; then
    ls_say ""
    ls_say "  This is a bind-mount permission problem (typical on Fedora / RHEL with"
    ls_say "  SELinux). The compose file labels the SearXNG config folder through"
    ls_say "  SEARXNG_MOUNT_OPTS in .env, which should read:  SEARXNG_MOUNT_OPTS=,z"
    ls_say "  Check:  grep SEARXNG .env ; getenforce"
    ls_say "  Then restart with ./run.sh (or re-run the installer)."
  fi
  return 1
}

# ---- keep the window open --------------------------------------------------------
# A terminal opened by a file manager / launcher closes the moment the script ends,
# taking all output with it. When no interactive shell started us, wait for a key press
# before exiting (Run.bat / Install.bat do the same with `pause`).
#   LOCAL_SEARCH_PAUSE=0    never wait      LOCAL_SEARCH_PAUSE=1   always wait (on a terminal)
ls_launched_from_shell() {   # 0 = an interactive shell started us (the terminal stays open)
  local pid="${PPID:-0}" comm="" args="" hops=0
  command -v ps >/dev/null 2>&1 || return 1
  while [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 8 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')"; comm="${comm##*/}"; comm="${comm#-}"
    args="$(ps -o args= -p "$pid" 2>/dev/null)"
    case "$comm" in
      bash|zsh|sh|dash|fish|ksh|mksh|ash|tcsh|csh|nu|elvish|xonsh)
        # `sh -c "./script"` is just a launcher's wrapper - look through it
        case " $args " in *" -c "*) ;; *) return 0 ;; esac ;;
      sudo|doas|env|time|timeout|nice|setsid|stdbuf|script|pkexec|su|nohup) ;;
      *) return 1 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"; hops=$((hops + 1))
  done
  return 1
}

ls_pause_now() {
  printf '\n'
  printf 'Press any key to close this window... '
  read -n 1 -s _ls_x </dev/tty 2>/dev/null || read -n 1 -s _ls_x 2>/dev/null || sleep 30
}

ls_pause_on_exit() {
  case "$(ls_lower "${LOCAL_SEARCH_PAUSE:-auto}")" in
    0|no|false|never) return 0 ;;
    1|yes|true|always) ;;
    *) ls_launched_from_shell && return 0 ;;
  esac
  { [ -t 0 ] && [ -t 1 ]; } || return 0
  # shellcheck disable=SC2154
  trap '_ls_rc=$?; ls_pause_now; exit $_ls_rc' EXIT
}

# ---- inherited proxy variables ----------------------------------------------------
# Podman copies the host shell's http_proxy / https_proxy / ... into every container
# (Docker does not). A loopback value such as http://127.0.0.1:7890 points at the
# container itself there, so every outgoing request fails at once ("Failed to connect over
# proxy 127.0.0.1 after 0 ms") although every container shows "Up". What the containers
# actually received is inspected, and exactly those loopback variables are blanked through a
# generated docker-compose.override.yml (docker compose and podman-compose load it
# automatically). Proxies that point at a real host (corporate, LAN) are left alone.
LS_OVERRIDE="docker-compose.override.yml"
LS_OVERRIDE_MARK="# local-search: generated container-network workaround"
LS_OVR_PROXY=""      # space separated (lowercase) proxy variable names blanked by the override

ls_override_is_ours() { [ -f "$LS_OVERRIDE" ] && head -n 1 "$LS_OVERRIDE" 2>/dev/null | grep -q "^# local-search: generated container-"; }

# Restore the variable list from an override this tool wrote earlier.
ls_override_load() {
  LS_OVR_PROXY=""
  ls_override_is_ours || return 0
  LS_OVR_PROXY="$(sed -n 's/^# ls-proxy-vars: *//p' "$LS_OVERRIDE" | head -n 1 | tr 'A-Z ' 'a-z\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ *$//')"
}

# Writes the override from LS_OVR_PROXY; removes it when the list is empty.
ls_override_write() {
  local svc v uc
  if [ -z "$LS_OVR_PROXY" ]; then rm -f "$LS_OVERRIDE"; return 0; fi
  {
    echo "$LS_OVERRIDE_MARK (safe to delete - the installer rewrites it)"
    echo "# ls-proxy-vars: $LS_OVR_PROXY"
    echo "# Proxy variables copied from the host shell point at 127.0.0.1, which inside a container is"
    echo "# the container itself: blanked for every service that needs the internet."
    echo "services:"
    for svc in searxng firecrawl playwright-service browserless; do
      echo "  $svc:"
      echo "    environment:"
      for v in $LS_OVR_PROXY; do
        uc="$(printf '%s' "$v" | tr '[:lower:]' '[:upper:]')"
        echo "      - \"$v=\""
        echo "      - \"$uc=\""
      done
    done
  } > "$LS_OVERRIDE"
}

# Prints "NAME=value" for every proxy variable inside the SearXNG container that points at
# this very container (localhost / 127.x / ::1), one per line. Nothing when all is well.
ls_container_loopback_proxies() {
  local envtxt line name val host
  envtxt="$("$ENGINE" exec local-search-searxng env 2>/dev/null)" || return 0
  while IFS= read -r line; do
    name="${line%%=*}"; val="${line#*=}"
    case "$(ls_lower "$name")" in http_proxy|https_proxy|all_proxy|ftp_proxy) ;; *) continue ;; esac
    [ -n "$val" ] || continue
    host="${val#*://}"; host="${host##*@}"
    case "$host" in
      \[*) host="${host#\[}"; host="${host%%\]*}" ;;
      *)   host="${host%%[:/]*}" ;;
    esac
    case "$host" in localhost|127.*|::1|0.0.0.0) printf '%s=%s\n' "$name" "$val" ;; esac
  done <<EOF
$envtxt
EOF
}

ls_wait_http() {   # ls_wait_http PORT SECONDS
  local waited=0
  while ! ls_http_ok "$1"; do
    [ "$waited" -ge "$2" ] && return 1
    sleep 2; waited=$((waited + 2))
  done
}

# ls_fix_container_proxy PORT  (run from the install folder; needs $DC and the stack up)
ls_fix_container_proxy() {
  local port="$1" bad names v out
  [ "${LOCAL_SEARCH_VERIFY_TIMEOUT:-90}" -gt 0 ] 2>/dev/null || return 0
  ls_say "Checking the containers' proxy settings..."
  bad="$(ls_container_loopback_proxies)"
  if [ -z "$bad" ]; then ls_ok "The containers' proxy settings are fine."; return 0; fi

  ls_err "The containers inherited a proxy setting that cannot work from inside a container:"
  printf '%s\n' "$bad" | sed 's/^/      /'
  ls_say "  (Podman copies your shell's proxy variables into every container; 127.0.0.1 there is"
  ls_say "   the container itself, so every outgoing request fails at once - searches stay empty.)"
  if [ -f "$LS_OVERRIDE" ] && ! ls_override_is_ours; then
    ls_say "  $LS_OVERRIDE exists and is not ours, so I will not change it. Add to the 'environment:' of"
    ls_say "  searxng, firecrawl, playwright-service and browserless, set to empty:"
    ls_say "    http_proxy=   https_proxy=   all_proxy=   (and the UPPERCASE twins)"
    return 1
  fi
  ls_override_load
  names=""
  while IFS= read -r v; do [ -n "$v" ] && names="$names $(ls_lower "${v%%=*}")"; done <<EOF
$bad
EOF
  # shellcheck disable=SC2086
  LS_OVR_PROXY="$(printf '%s\n' $LS_OVR_PROXY $names | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  ls_say "  -> removing those variables inside the containers (written to $LS_OVERRIDE)..."
  ls_override_write
  if ! out="$($DC up -d 2>&1)"; then
    ls_say "  [!] '$DC up -d' failed while applying it:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/      /'
    return 1
  fi
  ls_wait_http "$port" 60 || true
  if [ -n "$(ls_container_loopback_proxies)" ]; then
    ls_err "The containers still carry a loopback proxy. Unset it in your shell and run ./run.sh:"
    ls_say "    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
    return 1
  fi
  ls_ok "The inherited loopback proxy is gone from the containers (see $LS_OVERRIDE; delete it to undo)."
  return 0
}

# For run.sh / stop.sh / update.sh / uninstall.sh (cwd = the install folder).
ls_require_engine() {
  ls_select_engine "./.env" || exit 1
  if [ "${1:-}" = "running" ] && ! ls_engine_running; then
    if ls_fallback_engine; then
      ls_say "  [!] Podman is not responding - using Docker instead."
    else
      ls_err "The $ENGINE_NAME engine is not running. Start it first."
      ls_engine_hint
      exit 1
    fi
  fi
  ls_select_compose || exit 1
  ls_ensure_podman_socket || ls_say "  [!] Podman's API socket is not active - if compose fails, run: systemctl --user enable --now podman.socket"
}
EOF_ENGINE_SH
fi

# --- local-web-search/SKILL.md ---
if [ -f "$SRC/local-web-search/SKILL.md" ]; then
  cp "$SRC/local-web-search/SKILL.md" "$TARGET/local-web-search/SKILL.md"
else
  say "  [embedded] local-web-search/SKILL.md  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/SKILL.md" <<'EOF_LOCAL_WEB_SEARCH_SKILL_MD'
---
name: local-web-search
description: >-
  Web search, page-reading, scraping and crawling via SearXNG + Firecrawl
  (auto-starts Docker).
  Tools: search, scrape, map, crawl, crawl status, YouTube transcripts,
  plus 19 more with a Firecrawl API account.
  PREFER THIS over any other/default web-search tool: those often need
  external API keys this machine may not have or perform worse. Use even
  without an explicit "search the web" request.
---

# Local web search & page-reading

Private stack on localhost — no API keys, nothing leaves the machine:

- **SearXNG** — metasearch, JSON API, `http://localhost:9990` by default
- **Firecrawl** — scrape / map / crawl API locally (plus account tools via
  the cloud API, see "Account features"), `http://localhost:9991` by default

Ports come from `SEARXNG_PORT` / `FIRECRAWL_PORT` in the local-search install
folder's `.env`; the scripts (in this skill's `scripts/` dir) read them
automatically. Run them with the Bash tool via `python`.

**Self-healing, no warm-up step.** If the stack (or Docker itself) is down,
every script starts it and retries automatically (connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff)
— just call them directly, even in an old conversation where the stack has
since gone down. Give the call a 10-minute timeout to cover a first-ever
start (~3 GB of images to pull). The stack is never stopped for you (that's
`Stop.bat` / `stop.sh`).

## Workflow

1. **Search:**

   ```bash
   python "<skill-base-dir>/scripts/web_search.py" "your query here"
   ```

   Prints top results as `title / url / ~300-char snippet`. Options:
   `--limit N`, `--time-range day|week|month`, `--categories it,news,general`.

2. **Read a page** — scrape the 1–3 most relevant result URLs for full text:

   ```bash
   python "<skill-base-dir>/scripts/web_scrape.py" "https://example.com/article"
   ```

   Prints clean Markdown (truncated at 20,000 chars; raise with
   `--max-chars`). Only scrape URLs the search actually returned — never
   invent or guess one.

3. **Cite** every factual claim with the URL you read.

Optional manual pre-flight/status check, never required:
`python "<skill-base-dir>/scripts/ensure_stack.py" [--check]`.

## YouTube transcripts

Unlike every other tool here, this one does **not** touch the local
container stack — it talks directly to YouTube through **yt-dlp**, so there's
nothing to self-heal and no warm-up needed. It's the one tool in this skill
with a pip dependency (everything else is stdlib-only), and it also needs a
JavaScript runtime (Deno or Node.js 22+) on `PATH` because YouTube requires
one now:

```bash
pip install -U "yt-dlp[default]"   # one-time (includes yt-dlp-ejs)
python "<skill-base-dir>/scripts/web_youtube_transcript.py" "<video_id or URL>" [--lang en,de]
```

Prints each caption line as `[MM:SS] text`. Takes a bare video ID (the `v=`
value from the URL, or the part after `youtu.be/`) or a full URL; `--lang`
picks the caption language(s), default `en` (auto-generated captions count).
YouTube protects many videos' captions with a "PO token" that older scrapers
(`youtube-transcript-api`) cannot get — they receive an empty answer — which is
why yt-dlp is the engine; the old package is only used as a fallback when yt-dlp
is missing or fails. On failure the script says why (bot check, no captions
plus the languages that do exist, missing JavaScript runtime, …). If it fails
for every video, update first: `pip install -U "yt-dlp[default]"` — YouTube
changes often and yt-dlp follows within days.

## The full tool set (24 Firecrawl MCP-equivalent tools)

Beyond search + scrape, the skill exposes the complete Firecrawl MCP tool
surface as scripts. All of them share the self-healing behaviour, print
clean output by default, and support `--json` for the raw API response.
Exit codes: 0 success, 1 tool failure, 2 usage error.

This variant of the skill is installed when a Firecrawl account was
configured at install time; without one, only the free local tools are
installed (see the skill's core-only SKILL.md).

### Map & crawl — discover and collect site content

- **Map a website** (list the URLs under it, no page content):

  ```bash
  python "<skill-base-dir>/scripts/web_map.py" "https://example.com" [--search term] [--limit N]
  ```

- **Run a site crawl** (starts a multi-page crawl, polls it to completion,
  prints each page's URL + markdown):

  ```bash
  python "<skill-base-dir>/scripts/web_crawl.py" "https://example.com" [--limit N]
  ```

  Use `--limit N` to bound the crawl itself (the crawl otherwise walks the
  entire site — on a large site that can take many minutes). Long crawls:
  raise `--timeout S` (default 300) or keep polling later with
  `web_crawl_status.py <id>`; bound the printed output with `--max-pages N`
  (default 25) / `--max-chars N` (default 2000 per page).

- **Get crawl status** for an existing crawl ID:

  ```bash
  python "<skill-base-dir>/scripts/web_crawl_status.py" "<id>"
  ```

### Research agent — asynchronous multi-source synthesis (account feature)

- **Start a research agent job** from a prompt (+ optional seed URLs):

  ```bash
  python "<skill-base-dir>/scripts/web_agent.py" "research question" [seed_url ...]
  ```

- **Get agent job status / results** (poll until `completed` or `failed`;
  research commonly takes several minutes):

  ```bash
  python "<skill-base-dir>/scripts/web_agent_status.py" "<id>"
  ```

  If the job cannot finish in time, fall back to `web_search.py` +
  `web_scrape.py` to gather evidence synchronously.

### Interact — drive a live browser session (account feature)

- **Interact with a page** (click, fill fields, run browser code; acts on
  the LIVE site — form submissions can have persistent side effects):

  ```bash
  python "<skill-base-dir>/scripts/web_interact.py" (--scrape-id ID | --url URL) (--prompt "..." | --code "..." [--language bash|python|node])
  ```

- **Stop an interact session:**

  ```bash
  python "<skill-base-dir>/scripts/web_interact_stop.py" "<scrapeId>"
  ```

### Parse — local documents (account feature)

- **Parse a local file** (HTML, PDF, Word, RTF, OpenDocument, spreadsheets)
  into markdown / links / a summary / structured JSON:

  ```bash
  python "<skill-base-dir>/scripts/web_parse.py" "<filePath>" [--formats markdown,links,summary,json]
  ```

  The file is uploaded to the Firecrawl API the scripts are pointed at —
  with an account that is the cloud API, so the document LEAVES the
  machine. Web URLs belong in `web_scrape.py`.

### Monitors — recurring change tracking (account feature)

Recurring scrape/crawl/search checks that diff each run against its
predecessor. Requires a Firecrawl account API key — see "Account features"
below; the self-hosted stack may not serve these endpoints.

```bash
python "<skill-base-dir>/scripts/web_monitor_create.py"  --body '{"name":"...","goal":"...","targets":[...]}'
python "<skill-base-dir>/scripts/web_monitor_list.py"    [--limit N] [--offset N]
python "<skill-base-dir>/scripts/web_monitor_get.py"     "<id>"
python "<skill-base-dir>/scripts/web_monitor_update.py"  "<id>" --body '{"state":"paused"}'
python "<skill-base-dir>/scripts/web_monitor_delete.py"  "<id>"
python "<skill-base-dir>/scripts/web_monitor_run.py"     "<id>"
python "<skill-base-dir>/scripts/web_monitor_checks.py"  "<id>" [--status completed]
python "<skill-base-dir>/scripts/web_monitor_check.py"   "<id>" "<checkId>"
```

`web_monitor_create.py` takes the full monitor JSON via `--body '{...}'` or
`--body-file FILE`. Checks report page diffs (`same` / `new` / `changed` /
`removed` / `error`).

### Research papers — biomedical + arXiv literature (account feature)

The paper index (abstracts + full text across PubMed, bioRxiv, medRxiv,
arXiv, DOIs). Requires research permissions — see "Account features".

```bash
python "<skill-base-dir>/scripts/web_research_search.py"  "natural language topic"
python "<skill-base-dir>/scripts/web_research_inspect.py" "arxiv:1706.03762"
python "<skill-base-dir>/scripts/web_research_related.py" "arxiv:1706.03762" --intent "what to rank for" [--mode similar|citers|references]
python "<skill-base-dir>/scripts/web_research_read.py"    "arxiv:1706.03762" "specific question"
```

Paper IDs accept `arxiv:`, `pmcid:`, `pmid:`, and `doi:` identifiers.
Several distinct framings of the same question surface different papers.
For research-affiliated *websites* (not papers), use `web_search.py` with
`--categories research` instead.

### GitHub & developer search (account features)

```bash
python "<skill-base-dir>/scripts/web_github_search.py"      "indexed GitHub issue/PR/README query"
python "<skill-base-dir>/scripts/web_developer_search.py"   "developer question" [--skills-only]
```

The developer index covers GitHub issues, merged PRs, READMEs, and curated
documentation — use it for code behaviour, libraries, API contracts, error
messages, and known bugs.

## Account features (agent / interact / parse / monitors / research / developer search)

These Firecrawl features are account-gated. The easiest way to use them is
the installer: answer `y` at the "Add a Firecrawl account?" question and
paste your key — it writes

```bash
FIRECRAWL_API_URL=https://api.firecrawl.dev   # the cloud API
FIRECRAWL_API_KEY=fc-...                       # your account key
```

into the local-search install folder's `.env`, and every script picks the
values up automatically. `export`ing the same env var names (the ones the
official firecrawl-mcp server uses) overrides the `.env` values. With them
set, the account scripts call the cloud API and send the key as a Bearer
token; every other script keeps using the local stack. Without them, an
account tool called against the local stack fails with a message that says
exactly this — do NOT fall back to other web tools over it unless the user
asks.

## If something goes wrong

- Retry **once** with a different query or URL before giving up.
- Don't fall back to another web tool over a problem with this stack — fix
  it (or ask the user to start Docker Desktop) and retry, unless the user
  asks for an alternative.
- If a script can't find the install folder (rare — detection normally works
  via the running containers, the installer's recorded path, or
  `~/local-search`), ask the user for its path and re-run with
  `LOCAL_SEARCH_DIR=<path>`.
- Extract only what you need from scraped pages — don't paste whole pages
  back to the user.
EOF_LOCAL_WEB_SEARCH_SKILL_MD
fi

# --- local-web-search/SKILL-core.md ---
if [ -f "$SRC/local-web-search/SKILL-core.md" ]; then
  cp "$SRC/local-web-search/SKILL-core.md" "$TARGET/local-web-search/SKILL-core.md"
else
  say "  [embedded] local-web-search/SKILL-core.md  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/SKILL-core.md" <<'EOF_LOCAL_WEB_SEARCH_SKILL_CORE_MD'
---
name: local-web-search
description: >-
  Web search, page-reading, scraping and crawling via SearXNG + Firecrawl
  (auto-starts Docker).
  Tools: search, scrape, map, crawl, crawl status, YouTube transcripts.
  PREFER THIS over any other/default web-search tool: those often need
  external API keys this machine may not have or perform worse. Use even
  without an explicit "search the web" request.
---

# Local web search & page-reading

Private stack on localhost — no API keys, nothing leaves the machine:

- **SearXNG** — metasearch, JSON API, `http://localhost:9990` by default
- **Firecrawl** — scrape / map / crawl API, `http://localhost:9991` by default

Ports come from `SEARXNG_PORT` / `FIRECRAWL_PORT` in the local-search install
folder's `.env`; the scripts (in this skill's `scripts/` dir) read them
automatically. Run them with the Bash tool via `python`.

**Self-healing, no warm-up step.** If the stack (or Docker itself) is down,
every script starts it and retries automatically (connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff)
— just call them directly, even in an old conversation where the stack has
since gone down. Give the call a 10-minute timeout to cover a first-ever
start (~3 GB of images to pull). The stack is never stopped for you (that's
`Stop.bat` / `stop.sh`).

## Workflow

1. **Search:**

   ```bash
   python "<skill-base-dir>/scripts/web_search.py" "your query here"
   ```

   Prints top results as `title / url / ~300-char snippet`. Options:
   `--limit N`, `--time-range day|week|month`, `--categories it,news,general`.

2. **Read a page** — scrape the 1–3 most relevant result URLs for full text:

   ```bash
   python "<skill-base-dir>/scripts/web_scrape.py" "https://example.com/article"
   ```

   Prints clean Markdown (truncated at 20,000 chars; raise with
   `--max-chars`). Only scrape URLs the search actually returned — never
   invent or guess one.

3. **Cite** every factual claim with the URL you read.

Optional manual pre-flight/status check, never required:
`python "<skill-base-dir>/scripts/ensure_stack.py" [--check]`.

## YouTube transcripts

Unlike every other tool here, this one does **not** touch the local
container stack — it talks directly to YouTube through **yt-dlp**, so there's
nothing to self-heal and no warm-up needed. It's the one tool in this skill
with a pip dependency (everything else is stdlib-only), and it also needs a
JavaScript runtime (Deno or Node.js 22+) on `PATH` because YouTube requires
one now:

```bash
pip install -U "yt-dlp[default]"   # one-time (includes yt-dlp-ejs)
python "<skill-base-dir>/scripts/web_youtube_transcript.py" "<video_id or URL>" [--lang en,de]
```

Prints each caption line as `[MM:SS] text`. Takes a bare video ID (the `v=`
value from the URL, or the part after `youtu.be/`) or a full URL; `--lang`
picks the caption language(s), default `en` (auto-generated captions count).
YouTube protects many videos' captions with a "PO token" that older scrapers
(`youtube-transcript-api`) cannot get — they receive an empty answer — which is
why yt-dlp is the engine; the old package is only used as a fallback when yt-dlp
is missing or fails. On failure the script says why (bot check, no captions
plus the languages that do exist, missing JavaScript runtime, …). If it fails
for every video, update first: `pip install -U "yt-dlp[default]"` — YouTube
changes often and yt-dlp follows within days.

## Map & crawl — discover and collect site content

- **Map a website** (list the URLs under it, no page content):

  ```bash
  python "<skill-base-dir>/scripts/web_map.py" "https://example.com" [--search term] [--limit N]
  ```

- **Run a site crawl** (starts a multi-page crawl, polls it to completion,
  prints each page's URL + markdown):

  ```bash
  python "<skill-base-dir>/scripts/web_crawl.py" "https://example.com" [--limit N]
  ```

  Use `--limit N` to bound the crawl itself (the crawl otherwise walks the
  entire site — on a large site that can take many minutes). Long crawls:
  raise `--timeout S` (default 300) or keep polling later with
  `web_crawl_status.py <id>`; bound the printed output with `--max-pages N`
  (default 25) / `--max-chars N` (default 2000 per page).

- **Get crawl status** for an existing crawl ID:

  ```bash
  python "<skill-base-dir>/scripts/web_crawl_status.py" "<id>"
  ```

## Optional: more tools via a Firecrawl account

This skill was installed without one, so it ships only the free local
tools. A paid Firecrawl cloud account can add more tools later if you want
them: re-run `install-local-search` and answer `y` to the
"Add a Firecrawl account?" question (the installer writes the credentials
into the install folder's `.env` for you and installs the extra scripts).

## If something goes wrong

- Retry **once** with a different query or URL before giving up.
- Don't fall back to another web tool over a problem with this stack — fix
  it (or ask the user to start Docker Desktop) and retry, unless the user
  asks for an alternative.
- If a script can't find the install folder (rare — detection normally works
  via the running containers, the installer's recorded path, or
  `~/local-search`), ask the user for its path and re-run with
  `LOCAL_SEARCH_DIR=<path>`.
- Extract only what you need from scraped pages — don't paste whole pages
  back to the user.
EOF_LOCAL_WEB_SEARCH_SKILL_CORE_MD
fi

# --- local-web-search/SKILL-llm.md ---
if [ -f "$SRC/local-web-search/SKILL-llm.md" ]; then
  cp "$SRC/local-web-search/SKILL-llm.md" "$TARGET/local-web-search/SKILL-llm.md"
else
  say "  [embedded] local-web-search/SKILL-llm.md  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/SKILL-llm.md" <<'EOF_LOCAL_WEB_SEARCH_SKILL_LLM_MD'

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
EOF_LOCAL_WEB_SEARCH_SKILL_LLM_MD
fi

# --- local-web-search/scripts/config.py ---
if [ -f "$SRC/local-web-search/scripts/config.py" ]; then
  cp "$SRC/local-web-search/scripts/config.py" "$TARGET/local-web-search/scripts/config.py"
else
  say "  [embedded] local-web-search/scripts/config.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/config.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_CONFIG_PY'
"""Shared helpers for the local-web-search scripts: locating the local-search
install folder and the endpoints it is actually listening on.

The ports are NOT assumed: they are read from the install folder's .env
file (the same one the compose setup and Run.bat / Update.bat use), so if
the user picked custom ports during setup, every script follows them.
Defaults mirror the compose file's ${VAR:-default} fallbacks:
SearXNG 9990, Firecrawl 9991.
"""
import os
import shutil
import subprocess
import sys

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
EOF_LOCAL_WEB_SEARCH_SCRIPTS_CONFIG_PY
fi

# --- local-web-search/scripts/ensure_stack.py ---
if [ -f "$SRC/local-web-search/scripts/ensure_stack.py" ]; then
  cp "$SRC/local-web-search/scripts/ensure_stack.py" "$TARGET/local-web-search/scripts/ensure_stack.py"
else
  say "  [embedded] local-web-search/scripts/ensure_stack.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/ensure_stack.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_ENSURE_STACK_PY'
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
EOF_LOCAL_WEB_SEARCH_SCRIPTS_ENSURE_STACK_PY
fi

# --- local-web-search/scripts/firecrawl_api.py ---
if [ -f "$SRC/local-web-search/scripts/firecrawl_api.py" ]; then
  cp "$SRC/local-web-search/scripts/firecrawl_api.py" "$TARGET/local-web-search/scripts/firecrawl_api.py"
else
  say "  [embedded] local-web-search/scripts/firecrawl_api.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/firecrawl_api.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_FIRECRAWL_API_PY'
#!/usr/bin/env python3
"""Shared Firecrawl HTTP client for the local-web-search web_* scripts.

Every script that talks to the Firecrawl API (web_scrape.py, web_map.py,
web_crawl.py, ... web_developer_search.py) goes through this module, which
adds the same self-healing behaviour as web_search.py / web_scrape.py:

  * on a CONNECTION error (stack down), the local-search stack is started
    automatically (ensure_stack.py logic: Docker engine + `docker compose
    up -d`) and the request is retried once — only when talking to the LOCAL
    stack, never for a remote FIRECRAWL_API_URL,
  * transient HTTP statuses (429 / 5xx) are retried with a short backoff,
  * every failure is reported as an FcError with a clear, actionable message.

Endpoints: the base URL defaults to the local Firecrawl instance (port from
FIRECRAWL_PORT in the install folder's .env, default 9991). Two settings —
the same names the official firecrawl-mcp server uses — override it. Each
is read from the process environment FIRST, then from the install folder's
.env (where install-local-search persists the credentials when you answer
'y' to its "Add a Firecrawl account?" question):

  FIRECRAWL_API_URL    base URL of a Firecrawl API (e.g. the cloud API,
                       https://api.firecrawl.dev). Set this to use account
                       features (agent, interact, parse, monitors, research,
                       developer search) that the self-hosted instance does
                       not expose.
  FIRECRAWL_API_KEY    sent as `Authorization: Bearer <key>` when set —
                       required by the cloud API and account features.

Usage from a sibling script:

    import firecrawl_api as fc
    data = fc.call("/v1/map", method="POST", body={"url": url})

`call()` returns the parsed JSON response as a dict and raises FcError on
any failure (after the retries described above).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so error messages and progress output containing
# non-ASCII text never crash with a UnicodeEncodeError. Skipped if
# PYTHONIOENCODING is already set — an explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

# Default timeout per HTTP attempt (seconds); callers can override.
TIMEOUT = 90

# Transient statuses worth retrying: rate limit + common server errors.
RETRY_STATUSES = (429, 500, 502, 503, 504)
# Backoff before each retry (seconds): one entry per retry.
RETRY_BACKOFF = (1, 3)

# Cached view of the install folder's .env (lazily computed once: resolving
# the install folder may query Docker). Holds the FIRECRAWL_API_URL /
# FIRECRAWL_API_KEY values the installer wrote when a Firecrawl account was
# configured at install time.
_INSTALL_ENV = None


def _install_env():
    """The install folder's .env as a dict (see config.load_env), cached."""
    global _INSTALL_ENV
    if _INSTALL_ENV is None:
        try:
            _INSTALL_ENV = config.load_env(config.find_install_dir())
        except Exception:
            _INSTALL_ENV = {}
    return _INSTALL_ENV


def _setting(name):
    """Value of FIRECRAWL_API_URL / FIRECRAWL_API_KEY: the process
    environment first (the same override the official firecrawl-mcp server
    honours), then the install folder's .env. Stripped, possibly empty."""
    val = (os.environ.get(name) or "").strip()
    if val:
        return val
    return (_install_env().get(name) or "").strip()


class FcError(Exception):
    """A Firecrawl API failure after all retries, with a user-facing hint.

    Attributes:
        message  what went wrong (single line)
        status   HTTP status code, or None for connection/protocol errors
        hint     optional extra guidance printed by the CLI scripts
    """

    def __init__(self, message, status=None, hint=None):
        super().__init__(message)
        self.status = status
        self.hint = hint


def base_url():
    """The Firecrawl base URL: FIRECRAWL_API_URL when set in the environment
    or the install folder's .env (self-hosted remote or the cloud API),
    otherwise the local stack's endpoint (FIRECRAWL_PORT from the install
    folder's .env, default 9991)."""
    override = _setting("FIRECRAWL_API_URL")
    if override:
        return override.rstrip("/")
    return config.endpoints(config.find_install_dir())["firecrawl"]


def is_local():
    """True when requests go to the LOCAL stack (no FIRECRAWL_API_URL in the
    environment or the install folder's .env), i.e. self-healing a down
    stack can help."""
    return not _setting("FIRECRAWL_API_URL")


def url(path):
    """Absolute URL for an API path like '/v1/map' (see base_url())."""
    return base_url() + path


def auth_headers():
    """Headers for a JSON request: content type + optional Bearer auth from
    FIRECRAWL_API_KEY (environment or install .env; needed for account
    features / the cloud API)."""
    headers = {"Content-Type": "application/json"}
    key = _setting("FIRECRAWL_API_KEY")
    if key:
        headers["Authorization"] = "Bearer " + key
    return headers


def _selfheal():
    """Start the container engine + the containers if they are down (the same
    logic as ensure_stack.py). Import is deferred so the fast path (stack
    already up) pays nothing. Returns (ok, message)."""
    try:
        import ensure_stack
        ok, message, _code = ensure_stack.ensure_ready()
        return ok, message
    except Exception as e:  # unexpected self-heal failure: degrade gracefully
        return False, "self-heal failed unexpectedly: {}".format(e)


def _read_body(e):
    """Best-effort error body from an HTTPError (JSON message or raw text)."""
    try:
        raw = e.read()
    except Exception:
        return ""
    text = raw.decode("utf-8", "replace")[:800]
    try:
        payload = json.loads(text)
        msg = payload.get("error") or payload.get("message")
        if isinstance(msg, str) and msg:
            return msg
    except Exception:
        pass
    return text


def _hint_for_status(status):
    """Actionable guidance for the statuses account-gated endpoints return."""
    if status in (401, 403):
        return ("This tool needs an authenticated Firecrawl account: set "
                "FIRECRAWL_API_KEY (and FIRECRAWL_API_URL=https://api.firecrawl.dev "
                "to use the cloud API) and retry.")
    if status == 404:
        return ("This endpoint is not available on the Firecrawl instance it "
                "was called against. Account tools (monitor / research / "
                "developer search) need the cloud API: set "
                "FIRECRAWL_API_URL=https://api.firecrawl.dev and "
                "FIRECRAWL_API_KEY, then retry.")
    if status in RETRY_STATUSES:
        return ("The Firecrawl service answered with a server error. Wait a "
                "moment and retry; if it persists, inspect the stack with: "
                "cd <install folder> && docker compose logs --tail 50 firecrawl "
                "(or `podman compose logs ...` if the stack runs on Podman)")
    return None


def _request(endpoint, method, body_bytes, headers, timeout):
    """One raw HTTP attempt. Raises HTTPError (service answered with an
    error status — service is UP) or URLError-family (connection problem —
    service is DOWN). Returns the parsed JSON response."""
    req = urllib.request.Request(endpoint, data=body_bytes,
                                 headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        text = r.read().decode("utf-8", "replace")
    if not text.strip():
        return {}
    try:
        return json.loads(text)
    except ValueError:
        raise FcError("Firecrawl returned a non-JSON response: "
                      + text[:300])


def call(path, method="GET", body=None, query=None, timeout=TIMEOUT):
    """Call the Firecrawl API with retries + self-healing.

    path    API path, e.g. "/v1/map" or "/v1/crawl/<id>" (already encoded)
    method  HTTP method (GET / POST / PATCH / DELETE)
    body    JSON-serialisable request body (dict) or None
    query   dict of query-string parameters (skipped when empty/None)
    timeout seconds per HTTP attempt

    Returns the parsed JSON response (dict). Raises FcError after the
    retries are exhausted (see module docstring for the retry policy)."""
    endpoint = url(path)
    if query:
        pairs = [(k, v) for k, v in query.items() if v is not None]
        if pairs:
            endpoint += "?" + urllib.parse.urlencode(pairs)
    body_bytes = None
    headers = auth_headers()
    if body is not None:
        body_bytes = json.dumps(body).encode("utf-8")

    attempts = 1 + len(RETRY_BACKOFF)  # initial + retries
    for attempt in range(1, attempts + 1):
        # ---- one attempt, classifying every failure mode -----------------
        try:
            return _request(endpoint, method, body_bytes, headers, timeout)
        except urllib.error.HTTPError as e:
            status = e.code
            detail = _read_body(e)
            if status in RETRY_STATUSES and attempt < attempts:
                wait = RETRY_BACKOFF[attempt - 1]
                print(f"Firecrawl answered {status} ({detail or 'server error'}) "
                      f"— retrying in {wait}s ...", file=sys.stderr)
                time.sleep(wait)
                continue
            raise FcError("HTTP {}{}{}".format(
                status, ": " + detail if detail else "",
                "" if attempt == 1 else f" (after {attempt} attempts)"),
                status=status, hint=_hint_for_status(status)) from e
        except FcError:
            raise
        except Exception as e:  # URLError / ConnectionError / timeout: DOWN
            if not is_local():
                raise FcError(
                    "could not reach {} ({}). Check the URL and your "
                    "network, then retry.".format(base_url(), e)) from e
            if attempt < attempts:
                # Local stack: try to bring it up, then retry the request.
                print(f"Stack unreachable ({e}) — starting it automatically ...",
                      file=sys.stderr)
                ok, message = _selfheal()
                if not ok:
                    raise FcError(
                        "the local-search stack could not be started: " + message
                        + " Resolve the stack (or ask the user to start Podman/Docker "
                          "Desktop) and retry — do NOT fall back to other web "
                          "tools unless the user asks.") from e
                continue
            raise FcError(
                "request failed after the stack was started: {}".format(e)) from e
    # unreachable: the loop either returns or raises
    raise FcError("request failed unexpectedly")


def call_form(path, fields, file_path, file_field="file", timeout=TIMEOUT):
    """Call the Firecrawl API with a multipart/form-data body (used by
    web_parse.py to upload a local document).

    fields      dict of form fields (values are str / int / list)
    file_path   the file to upload (read in binary mode)
    file_field  the form field name for the file (Firecrawl: "file")
    """
    boundary = "----localwebsearch" + format(int(time.time() * 1000), "x")
    parts = []
    for key, val in (fields or {}).items():
        if val is None:
            continue
        values = val if isinstance(val, list) else [val]
        for v in values:
            parts.append(("--" + boundary).encode("utf-8"))
            parts.append(('Content-Disposition: form-data; name="{}"'
                          .format(key)).encode("utf-8"))
            parts.append(b"")
            parts.append(str(v).encode("utf-8"))
    try:
        with open(file_path, "rb") as fh:
            payload = fh.read()
    except OSError as e:
        raise FcError("could not read {}: {}".format(file_path, e))
    filename = os.path.basename(file_path)
    parts.append(("--" + boundary).encode("utf-8"))
    parts.append(('Content-Disposition: form-data; name="{}"; filename="{}"'
                  .format(file_field, filename)).encode("utf-8"))
    parts.append(b"Content-Type: application/octet-stream")
    parts.append(b"")
    parts.append(payload)
    parts.append(("--" + boundary + "--").encode("utf-8"))
    body = b"\r\n".join(parts)

    endpoint = url(path)
    headers = {
        "Content-Type": "multipart/form-data; boundary=" + boundary,
    }
    key = _setting("FIRECRAWL_API_KEY")
    if key:
        headers["Authorization"] = "Bearer " + key

    try:
        return _request(endpoint, "POST", body, headers, timeout)
    except urllib.error.HTTPError as e:
        status = e.code
        detail = _read_body(e)
        raise FcError("HTTP {}{}{}".format(
            status, ": " + detail if detail else ""),
            status=status, hint=_hint_for_status(status)) from e
    except FcError:
        raise
    except Exception as e:  # connection problem: stack (probably) down
        if not is_local():
            raise FcError(
                "could not reach {} ({}). Check the URL and your network, "
                "then retry.".format(base_url(), e)) from e
        print(f"Stack unreachable ({e}) — starting it automatically ...",
              file=sys.stderr)
        ok, message = _selfheal()
        if not ok:
            raise FcError("the local-search stack could not be started: "
                          + message) from e
        try:
            return _request(endpoint, "POST", body, headers, timeout)
        except urllib.error.HTTPError as e2:
            raise FcError("HTTP {}: {}".format(e2.code, _read_body(e2)),
                          status=e2.code,
                          hint=_hint_for_status(e2.code)) from e2
        except Exception as e2:
            raise FcError("request failed after the stack was started: "
                          "{}".format(e2)) from e2
EOF_LOCAL_WEB_SEARCH_SCRIPTS_FIRECRAWL_API_PY
fi

# --- local-web-search/scripts/web_search.py ---
if [ -f "$SRC/local-web-search/scripts/web_search.py" ]; then
  cp "$SRC/local-web-search/scripts/web_search.py" "$TARGET/local-web-search/scripts/web_search.py"
else
  say "  [embedded] local-web-search/scripts/web_search.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_search.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SEARCH_PY'
#!/usr/bin/env python3
"""Search the web via the local SearXNG instance and print compact results.

Usage:
    python web_search.py "your query" [--limit 8] [--time-range day|week|month]
                                  [--categories it,news,general]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the search once. You do NOT need
to run ensure_stack.py first — just run the search.

Prints up to `limit` results, each as:
    N. <title>
       <url>
       <snippet>
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so search results with non-ASCII text never crash
# with a UnicodeEncodeError. Skipped if PYTHONIOENCODING is already set —
# an explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

# Port comes from SEARXNG_PORT in the install folder's .env (default 9990).
BASE = config.endpoints(config.find_install_dir())["searxng"] + "/search"

TIMEOUT = 30  # seconds per HTTP attempt


def fetch(url):
    """GET the SearXNG JSON API. Raises HTTPError when the service answered
    with an error status (service is UP), URLError-family on connection
    problems (service is DOWN)."""
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def selfheal():
    """Start the Docker engine + the containers if they are down (the same
    logic as ensure_stack.py). Import is deferred so the fast path (stack
    already up) pays nothing. Returns (ok, message)."""
    try:
        import ensure_stack
        ok, message, _code = ensure_stack.ensure_ready()
        return ok, message
    except Exception as e:  # unexpected self-heal failure: degrade gracefully
        return False, "self-heal failed unexpectedly: {}".format(e)


def main() -> int:
    args = sys.argv[1:]
    limit, time_range, categories = 8, None, None
    query_parts = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--limit":
            i += 1
            limit = int(args[i])
        elif a == "--time-range":
            i += 1
            time_range = args[i]
        elif a == "--categories":
            i += 1
            categories = args[i]
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            query_parts.append(a)
        i += 1
    query = " ".join(query_parts).strip()
    if not query:
        print('usage: web_search.py "query" [--limit N] [--time-range R] [--categories C]', file=sys.stderr)
        return 2

    params = {"q": query, "format": "json", "language": "en"}
    if time_range:
        params["time_range"] = time_range
    if categories:
        params["categories"] = categories
    url = BASE + "?" + urllib.parse.urlencode(params)

    data = None
    try:
        data = fetch(url)
    except urllib.error.HTTPError as e:
        # The service ANSWERED (even with an error status) -> it is up;
        # starting containers would not help.
        print(f"SEARCH FAILED: {e}", file=sys.stderr)
        print("SearXNG answered with an error status (the stack is running). "
              "Retry once with a different query, or inspect the stack with: "
              "cd <install folder> && docker compose logs --tail 50 searxng",
              file=sys.stderr)
        return 1
    except Exception as e:
        # Connection error: the stack is (probably) down -> self-heal once,
        # then retry the search.
        print(f"Stack unreachable ({e}) — starting it automatically ...",
              file=sys.stderr)
        ok, message = selfheal()
        if not ok:
            print(message, file=sys.stderr)
            print("SEARCH FAILED: the local-search stack could not be started. "
                  "Resolve the stack (or ask the user to start Docker Desktop) "
                  "and retry — do NOT fall back to other web tools unless the "
                  "user asks.", file=sys.stderr)
            return 1
        try:
            data = fetch(url)
        except Exception as e2:
            print(f"SEARCH FAILED after the stack was started: {e2}", file=sys.stderr)
            return 1

    results = data.get("results", [])[:limit]
    if not results:
        print("(no results)")
        return 0
    for n, hit in enumerate(results, 1):
        title = (hit.get("title") or "").strip()
        result_url = hit.get("url") or ""
        content = (hit.get("content") or "").strip().replace("\n", " ")
        if len(content) > 300:
            content = content[:300] + "…"
        print(f"{n}. {title}")
        print(f"   {result_url}")
        if content:
            print(f"   {content}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SEARCH_PY
fi

# --- local-web-search/scripts/web_scrape.py ---
if [ -f "$SRC/local-web-search/scripts/web_scrape.py" ]; then
  cp "$SRC/local-web-search/scripts/web_scrape.py" "$TARGET/local-web-search/scripts/web_scrape.py"
else
  say "  [embedded] local-web-search/scripts/web_scrape.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_scrape.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SCRAPE_PY'
#!/usr/bin/env python3
"""Read a web page as clean Markdown via the local Firecrawl instance.

Usage:
    python web_scrape.py <url> [--max-chars 20000]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the scrape once. You do NOT need
to run ensure_stack.py first — just run the scrape.

Prints the page's Markdown to stdout, truncated at --max-chars.
"""
import json
import os
import sys
import urllib.error
import urllib.request

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so scraped page content with non-ASCII text never
# crashes with a UnicodeEncodeError. Skipped if PYTHONIOENCODING is already
# set — an explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # sibling module: install-dir lookup + .env-driven endpoints

# Port comes from FIRECRAWL_PORT in the install folder's .env (default 9991).
ENDPOINT = config.endpoints(config.find_install_dir())["firecrawl"] + "/v1/scrape"

TIMEOUT = 90  # seconds per HTTP attempt


def fetch(url):
    """POST the scrape request. Raises HTTPError when the service answered
    with an error status (service is UP), URLError-family on connection
    problems (service is DOWN)."""
    body = json.dumps({"url": url, "formats": ["markdown"]}).encode()
    req = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def selfheal():
    """Start the Docker engine + the containers if they are down (the same
    logic as ensure_stack.py). Import is deferred so the fast path (stack
    already up) pays nothing. Returns (ok, message)."""
    try:
        import ensure_stack
        ok, message, _code = ensure_stack.ensure_ready()
        return ok, message
    except Exception as e:  # unexpected self-heal failure: degrade gracefully
        return False, "self-heal failed unexpectedly: {}".format(e)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_scrape.py <url> [--max-chars N]", file=sys.stderr)
        return 2
    url = args[0]
    max_chars = 20000
    i = 1
    while i < len(args):
        if args[i] == "--max-chars" and i + 1 < len(args):
            max_chars = int(args[i + 1])
            i += 2
        else:
            i += 1

    data = None
    try:
        data = fetch(url)
    except urllib.error.HTTPError as e:
        # The service ANSWERED (even with an error status) -> it is up;
        # starting containers would not help.
        print(f"SCRAPE FAILED for {url}: {e}", file=sys.stderr)
        print("Firecrawl answered with an error status (the stack is running). "
              "Retry once with a different result URL, or inspect the stack "
              "with: cd <install folder> && docker compose logs --tail 50 "
              "firecrawl", file=sys.stderr)
        return 1
    except Exception as e:
        # Connection error: the stack is (probably) down -> self-heal once,
        # then retry the scrape.
        print(f"Stack unreachable ({e}) — starting it automatically ...",
              file=sys.stderr)
        ok, message = selfheal()
        if not ok:
            print(message, file=sys.stderr)
            print("SCRAPE FAILED for {}: the local-search stack could not be "
                  "started. Resolve the stack (or ask the user to start Docker "
                  "Desktop) and retry — do NOT fall back to other web tools "
                  "unless the user asks.".format(url), file=sys.stderr)
            return 1
        try:
            data = fetch(url)
        except Exception as e2:
            print(f"SCRAPE FAILED for {url} after the stack was started: {e2}",
                  file=sys.stderr)
            return 1

    payload = data.get("data") or {}
    markdown = payload.get("markdown") or "" if isinstance(payload, dict) else ""
    if not markdown:
        print("SCRAPE RETURNED NO MARKDOWN for", url, file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1

    if len(markdown) > max_chars:
        markdown = markdown[:max_chars] + f"\n\n[... truncated at {max_chars} chars ...]"
    print(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_SCRAPE_PY
fi

# --- local-web-search/scripts/web_extract.py ---
if [ -f "$SRC/local-web-search/scripts/web_extract.py" ]; then
  cp "$SRC/local-web-search/scripts/web_extract.py" "$TARGET/local-web-search/scripts/web_extract.py"
else
  say "  [embedded] local-web-search/scripts/web_extract.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_extract.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_EXTRACT_PY'
#!/usr/bin/env python3
"""LLM extraction from one or more URLs via the local Firecrawl /v1/extract
endpoint.

Runs on the OpenAI-compatible LLM connected in the installer
(OPENAI_BASE_URL / OPENAI_API_KEY / MODEL_NAME in the install folder's
.env); the endpoint may be local or remote. Without a configured LLM the
endpoint fails with a "model not configured" error, which is expected and
not a stack failure.

Usage:
    python web_extract.py <url> [url ...] --prompt "what to extract" [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or
the containers are down), this script automatically starts them (the same
logic as ensure_stack.py / Run.bat) and retries the request. Connection
failures self-heal once; transient 429/5xx answers are retried with a short
backoff. You do NOT need to run ensure_stack.py first — just run the script.

Prints the extracted result (the `data` field of the response). `--json`
prints the full raw API response instead.
Exit codes: 0 success, 1 tool failure, 2 usage error.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal


def main() -> int:
    args = sys.argv[1:]
    urls = []
    prompt = None
    as_json = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--prompt" and i + 1 < len(args):
            i += 1
            prompt = args[i]
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            urls.append(a)
        i += 1

    if not urls or not prompt:
        print('usage: web_extract.py <url> [url ...] --prompt "what to extract" [--json]',
              file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/extract", method="POST",
                       body={"urls": urls, "prompt": prompt})
    except fc.FcError as e:
        print(f"EXTRACT FAILED for {', '.join(urls)}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if not data.get("success", True) and not data.get("data"):
        print("EXTRACT FAILED for {}: no data returned. Response: "
              .format(", ".join(urls)), file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
    else:
        print(json.dumps(data.get("data"), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_EXTRACT_PY
fi

# --- local-web-search/scripts/web_youtube_transcript.py ---
if [ -f "$SRC/local-web-search/scripts/web_youtube_transcript.py" ]; then
  cp "$SRC/local-web-search/scripts/web_youtube_transcript.py" "$TARGET/local-web-search/scripts/web_youtube_transcript.py"
else
  say "  [embedded] local-web-search/scripts/web_youtube_transcript.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_youtube_transcript.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_YOUTUBE_TRANSCRIPT_PY'
#!/usr/bin/env python3
"""Fetch a YouTube video's transcript and print it as `[MM:SS] text` lines.

Usage:
    python web_youtube_transcript.py <video_id | youtube url> [--lang en,de]

Why yt-dlp: YouTube now protects the caption tracks of a growing share of
videos with a "PO token" (the track URL carries `exp=xpe`); a plain request
for such a track gets an EMPTY answer. `youtube-transcript-api` cannot produce
that token, yt-dlp can. So this script uses yt-dlp, which needs

    pip install -U "yt-dlp[default]"        # includes yt-dlp-ejs
    + a JavaScript runtime on PATH: Deno, or Node.js 22+ (Bun / QuickJS also work)

If yt-dlp is not installed (or fails) it falls back to the older
`youtube-transcript-api` package, which still works for videos that are not
behind the token yet.

Exit status: 0 = transcript printed, 1 = failed (reason on stderr), 2 = usage.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# Default stdout/stderr to UTF-8 regardless of the host locale/codepage
# (e.g. Windows cp1252), so transcripts with non-ASCII text never crash
# with a UnicodeEncodeError. Skipped if PYTHONIOENCODING is already set —
# an explicit override always wins.
if "PYTHONIOENCODING" not in os.environ:
    for _stream in (sys.stdout, sys.stderr):
        if hasattr(_stream, "reconfigure"):
            try:
                _stream.reconfigure(encoding="utf-8")
            except Exception:
                pass

VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
URL_ID = re.compile(r"(?:[?&]v=|youtu\.be/|/shorts/|/embed/|/live/|/v/)([A-Za-z0-9_-]{11})")
LANG = re.compile(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")
YTDLP_TIMEOUT = 180  # seconds


class TranscriptError(Exception):
    """A failure whose message is already written for the end user."""


def video_id_from(arg):
    arg = arg.strip()
    if VIDEO_ID.match(arg):
        return arg
    m = URL_ID.search(arg)
    return m.group(1) if m else None


# --------------------------------------------------------------------- yt-dlp
def ytdlp_command():
    """How to run yt-dlp, or None when it is not installed."""
    try:
        import yt_dlp  # noqa: F401
        return [sys.executable, "-m", "yt_dlp"]
    except ImportError:
        pass
    exe = shutil.which("yt-dlp")
    return [exe] if exe else None


def js_runtime_args():
    """(extra yt-dlp args, a runtime was found). yt-dlp itself only enables Deno."""
    if shutil.which("deno"):
        return [], True
    for exe, name in (("node", "node"), ("bun", "bun"), ("qjs", "quickjs"),
                      ("quickjs", "quickjs")):
        if shutil.which(exe):
            return ["--js-runtimes", name], True
    return [], False


def parse_json3(path):
    """YouTube's json3 caption file -> [(start_seconds, text), ...]."""
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    out = []
    for ev in data.get("events", []):
        segs = ev.get("segs")
        if not segs:
            continue
        text = "".join(s.get("utf8", "") for s in segs).replace("\n", " ").strip()
        if text:
            out.append(((ev.get("tStartMs") or 0) / 1000.0, text))
    return out


def pick_file(files, langs):
    """Best caption file for the requested languages (exact code, then -orig, then any)."""
    def rank(path):
        code = os.path.basename(path).split(".")[-2]  # <id>.<lang>.json3
        for i, lang in enumerate(langs):
            if code == lang:
                return (i, 0)
            if code == lang + "-orig":
                return (i, 1)
            if code.startswith(lang):
                return (i, 2)
        return (len(langs), 3)
    return sorted(files, key=rank)[0]


def available_languages(cmd, url):
    """Language codes yt-dlp reports for the video (for the 'no such language' message)."""
    try:
        proc = subprocess.run(cmd + ["--skip-download", "--list-subs", "--no-warnings", "--", url],
                              capture_output=True, encoding="utf-8", errors="replace",
                              timeout=YTDLP_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return []
    codes = []
    for line in proc.stdout.splitlines():
        parts = line.split()
        if (parts and not line.startswith(("[", " ")) and parts[0] != "Language"
                and re.match(r"^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$", parts[0])
                and parts[0] not in codes):
            codes.append(parts[0])
    return codes[:15]


def explain_ytdlp_failure(output, have_runtime):
    low = output.lower()
    if "sign in to confirm" in low or "not a bot" in low:
        why = ("YouTube asked for a sign-in / bot check for this request. This is common behind a "
               "VPN, proxy or on a datacenter connection - try again later or from another network.")
    elif ("javascript runtime" in low or "js runtime" in low or "n challenge" in low
          or "challenge solving failed" in low or "ejs" in low):
        why = ("yt-dlp could not solve YouTube's JavaScript challenge. Install Deno or Node.js 22+ "
               "and the yt-dlp-ejs package: pip install -U \"yt-dlp[default]\"")
    elif "po token" in low or "po_token" in low:
        why = "YouTube wants a PO token for this video and yt-dlp could not obtain one; update yt-dlp: pip install -U \"yt-dlp[default]\""
    elif ("private video" in low or "members-only" in low or "members only" in low
          or ("sign in" in low and "age" in low)):
        why = "The video is private, members-only or age-restricted - no public transcript is available."
    elif "video unavailable" in low or "this video is not available" in low or "has been removed" in low:
        why = "The video is unavailable (removed, private or region-locked)."
    elif "http error 429" in low or "too many requests" in low:
        why = "YouTube is rate-limiting this connection (HTTP 429). Wait a while and retry."
    else:
        errs = [ln.strip() for ln in output.splitlines() if "error" in ln.lower()]
        why = errs[-1] if errs else "yt-dlp finished without writing a transcript."
    if not have_runtime and "javascript" not in why.lower():
        why += (" (No JavaScript runtime - Deno or Node.js 22+ - was found on PATH; YouTube needs one for "
                "yt-dlp to work reliably.)")
    return why


def fetch_with_ytdlp(cmd, video_id, langs):
    url = "https://www.youtube.com/watch?v=" + video_id
    js_args, have_runtime = js_runtime_args()
    tmp = tempfile.mkdtemp(prefix="local-search-yt-")
    try:
        base = cmd + ["--skip-download", "--no-playlist", "--no-progress", "--no-warnings",
                      "--write-subs", "--write-auto-subs",
                      "--sub-langs", ",".join(l + ".*" for l in langs),
                      "--sub-format", "json3",
                      "-o", os.path.join(tmp, "%(id)s.%(ext)s")]
        proc = None
        for extra in ([js_args, []] if js_args else [[]]):
            try:
                proc = subprocess.run(base + extra + ["--", url], capture_output=True,
                                      encoding="utf-8", errors="replace", timeout=YTDLP_TIMEOUT)
            except subprocess.TimeoutExpired:
                raise TranscriptError("yt-dlp timed out after %d s." % YTDLP_TIMEOUT)
            except OSError as exc:
                raise TranscriptError("could not run yt-dlp: %s" % exc)
            if "no such option: --js-runtimes" not in proc.stderr:
                break  # an old yt-dlp without --js-runtimes is retried without it
        files = glob.glob(os.path.join(tmp, glob.escape(video_id) + ".*.json3"))
        if not files:
            output = (proc.stdout or "") + "\n" + (proc.stderr or "")
            if proc.returncode == 0 and "no subtitles" in output.lower():
                langs_found = available_languages(cmd, url)
                msg = "the video has no captions in: %s." % ", ".join(langs)
                if langs_found:
                    msg += " Available: %s - choose one with --lang." % ", ".join(langs_found)
                raise TranscriptError(msg)
            raise TranscriptError(explain_ytdlp_failure(output, have_runtime))
        lines = parse_json3(pick_file(files, langs))
        if not lines:
            raise TranscriptError("the caption file was empty.")
        return lines
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ------------------------------------------------- youtube-transcript-api (fallback)
def fetch_with_api(video_id, langs):
    from youtube_transcript_api import YouTubeTranscriptApi  # ImportError handled by caller
    transcript = YouTubeTranscriptApi().fetch(video_id, languages=langs)
    return [(seg.start, seg.text.replace("\n", " ")) for seg in transcript.snippets]


# ------------------------------------------------------------------------ main
def parse_args(argv):
    video, langs, i = None, ["en"], 0
    while i < len(argv):
        a = argv[i]
        if a in ("--lang", "--langs", "-l") and i + 1 < len(argv):
            langs = [x.strip() for x in argv[i + 1].split(",") if x.strip()]
            i += 2
        elif a.startswith("--lang="):
            langs = [x.strip() for x in a.split("=", 1)[1].split(",") if x.strip()]
            i += 1
        elif video is None and not a.startswith("-"):
            video = a
            i += 1
        else:
            return None, None
    if video is None or not langs or not all(LANG.match(l) for l in langs):
        return None, None
    return video, langs


def main(argv=None):
    video, langs = parse_args(sys.argv[1:] if argv is None else argv)
    if video is None:
        print("usage: web_youtube_transcript.py <video_id | youtube url> [--lang en,de]",
              file=sys.stderr)
        return 2
    video_id = video_id_from(video)
    if not video_id:
        print("TRANSCRIPT FAILED: '%s' is not a YouTube video id or URL." % video, file=sys.stderr)
        return 2

    problems = []
    lines = None
    cmd = ytdlp_command()
    if cmd:
        try:
            lines = fetch_with_ytdlp(cmd, video_id, langs)
        except TranscriptError as exc:
            problems.append("yt-dlp: %s" % exc)
    else:
        problems.append("yt-dlp is not installed.")

    if lines is None:
        try:
            lines = fetch_with_api(video_id, langs)
            if cmd:
                print("(yt-dlp failed - used the youtube-transcript-api fallback)", file=sys.stderr)
        except ImportError:
            pass
        except Exception as exc:  # noqa: BLE001 - library errors are user-facing text
            name = type(exc).__name__
            hint = (" (YouTube requires a PO token for this video - only yt-dlp can read it)"
                    if "PoToken" in name or "xpe" in str(exc) else "")
            problems.append("youtube-transcript-api: %s%s" % (name, hint))

    if lines is None:
        print("TRANSCRIPT FAILED for %s:" % video_id, file=sys.stderr)
        for p in problems:
            print("  - " + p, file=sys.stderr)
        if not cmd:
            print("Install the reliable engine:  pip install -U \"yt-dlp[default]\"\n"
                  "and have Deno or Node.js 22+ on PATH (YouTube needs a JavaScript runtime).",
                  file=sys.stderr)
        return 1

    for start, text in lines:
        mins, secs = int(start) // 60, int(start) % 60
        print("[%02d:%02d] %s" % (mins, secs, text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_YOUTUBE_TRANSCRIPT_PY
fi

# --- local-web-search/scripts/web_map.py ---
if [ -f "$SRC/local-web-search/scripts/web_map.py" ]; then
  cp "$SRC/local-web-search/scripts/web_map.py" "$TARGET/local-web-search/scripts/web_map.py"
else
  say "  [embedded] local-web-search/scripts/web_map.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_map.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MAP_PY'
#!/usr/bin/env python3
"""Map a website: enumerate the URLs Firecrawl indexes under it, without
fetching each page's content (the firecrawl_map MCP tool).

Usage:
    python web_map.py <url> [--search term] [--limit N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

`--search` filters/boosts URLs containing the term (server-side). Prints up
to `limit` URLs (default 100), one per line, numbered. `--json` prints the
raw API response instead.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/map")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_map.py <url> [--search term] [--limit N] [--json]",
              file=sys.stderr)
        return 2
    url = args[0]
    search, limit, as_json = None, 100, False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--search" and i + 1 < len(args):
            i += 1
            search = args[i]
        elif a == "--limit" and i + 1 < len(args):
            i += 1
            try:
                limit = int(args[i])
            except ValueError:
                print(f"invalid --limit: {args[i]}", file=sys.stderr)
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

    body = {"url": url}
    if search:
        body["search"] = search

    try:
        data = fc.call("/v1/map", method="POST", body=body)
    except fc.FcError as e:
        print(f"MAP FAILED for {url}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    links = data.get("links")
    if links is None:
        payload = data.get("data")
        if isinstance(payload, dict):
            links = payload.get("links")
    if not isinstance(links, list):
        links = []
    if not links:
        print("(no URLs found)")
        return 0
    for n, link in enumerate(links[:limit], 1):
        print(f"{n}. {link}")
    if len(links) > limit:
        print(f"[... {len(links) - limit} more URLs; raise --limit or use --json ...]",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MAP_PY
fi

# --- local-web-search/scripts/web_crawl.py ---
if [ -f "$SRC/local-web-search/scripts/web_crawl.py" ]; then
  cp "$SRC/local-web-search/scripts/web_crawl.py" "$TARGET/local-web-search/scripts/web_crawl.py"
else
  say "  [embedded] local-web-search/scripts/web_crawl.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_crawl.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_CRAWL_PY'
#!/usr/bin/env python3
"""Run a site crawl: start a multi-page Firecrawl crawl at a URL, poll it to
a terminal state, and report the final status and collected data (the
firecrawl_crawl MCP tool).

Usage:
    python web_crawl.py <url> [--limit N] [--timeout S] [--poll-interval S]
                        [--max-pages N] [--max-chars N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Polls the crawl every --poll-interval seconds (default 2) until it reaches a
terminal state (completed / failed / cancelled) or --timeout seconds elapse
(default 300). Progress is printed to stderr. When the crawl completes, each
collected page prints as `N. <url>` followed by its markdown truncated at
--max-chars chars (default 2000; up to --max-pages pages, default 25).
`--json` prints the final status response instead.

If the crawl has not finished within --timeout, the crawl ID and current
progress are printed — keep polling with web_crawl_status.py <id>.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/crawl")

# Crawl-job states that mean "no more polling".
TERMINAL = ("completed", "failed", "cancelled", "stopped")


def crawl_summary(data):
    """One-line status summary from a crawl-status payload."""
    status = data.get("status") or "unknown"
    completed = data.get("completed")
    total = data.get("total")
    if completed is not None and total is not None:
        return f"{status} ({completed}/{total} pages)"
    return str(status)


def print_pages(data, max_pages, max_chars):
    """Print the collected pages: `N. <url>` + truncated markdown."""
    pages = data.get("data")
    if not isinstance(pages, list) or not pages:
        return
    shown = pages[:max_pages]
    for n, page in enumerate(shown, 1):
        if not isinstance(page, dict):
            continue
        metadata = page.get("metadata")
        if not isinstance(metadata, dict):
            metadata = {}
        url = page.get("url") or page.get("sourceURL") \
            or metadata.get("url") or metadata.get("sourceURL") or "(no url)"
        print(f"{n}. {url}")
        markdown = page.get("markdown") or ""
        if markdown:
            if len(markdown) > max_chars:
                markdown = markdown[:max_chars] \
                    + f"\n   [... truncated at {max_chars} chars ...]"
            for line in markdown.splitlines() or [""]:
                print(f"   {line}")
    if len(pages) > max_pages:
        print(f"[... {len(pages) - max_pages} more pages; raise --max-pages "
              f"or use --json ...]", file=sys.stderr)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_crawl.py <url> [--limit N] [--timeout S] "
              "[--poll-interval S] [--max-pages N] [--max-chars N] [--json]",
              file=sys.stderr)
        return 2
    url = args[0]
    limit = None
    timeout, poll_every = 300, 2
    max_pages, max_chars, as_json = 25, 2000, False
    i = 1

    def num(name):
        # `i` already points at the option's value (the branch incremented it).
        try:
            return int(args[i])
        except (ValueError, IndexError):
            print(f"invalid {name}: {args[i] if i < len(args) else ''}",
                  file=sys.stderr)
            sys.exit(2)

    while i < len(args):
        a = args[i]
        if a == "--limit" and i + 1 < len(args):
            i += 1
            limit = num("--limit")
        elif a == "--timeout" and i + 1 < len(args):
            i += 1
            timeout = num("--timeout")
        elif a == "--poll-interval" and i + 1 < len(args):
            i += 1
            poll_every = num("--poll-interval")
        elif a == "--max-pages" and i + 1 < len(args):
            i += 1
            max_pages = num("--max-pages")
        elif a == "--max-chars" and i + 1 < len(args):
            i += 1
            max_chars = num("--max-chars")
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            print(f"unexpected argument: {a}", file=sys.stderr)
            return 2
        i += 1

    body = {"url": url}
    if limit:
        body["limit"] = limit

    # ---- start the crawl ------------------------------------------------
    try:
        started = fc.call("/v1/crawl", method="POST", body=body)
    except fc.FcError as e:
        print(f"CRAWL FAILED for {url}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1
    crawl_id = started.get("id") or (started.get("data") or {}).get("id")
    if not crawl_id:
        print("CRAWL FAILED for {}: the API did not return a crawl id. "
              "Response:".format(url), file=sys.stderr)
        print(json.dumps(started)[:800], file=sys.stderr)
        return 1
    print(f"Crawl started: {crawl_id}", file=sys.stderr)

    # ---- poll to a terminal state ---------------------------------------
    deadline = time.time() + timeout
    while True:
        try:
            data = fc.call("/v1/crawl/" + str(crawl_id), method="GET")
        except fc.FcError as e:
            print(f"CRAWL FAILED for {url}: status check failed: {e}",
                  file=sys.stderr)
            if e.hint:
                print(e.hint, file=sys.stderr)
            return 1
        status = str(data.get("status") or "unknown")
        if status in TERMINAL or (status not in
                                  ("active", "scraping", "queued", "processing",
                                   "waiting", "running") and data.get("data")):
            break
        if time.time() >= deadline:
            print(f"Crawl {crawl_id} still {crawl_summary(data)} after "
                  f"{timeout}s — keeping polling with:", file=sys.stderr)
            print(f"    python web_crawl_status.py {crawl_id}", file=sys.stderr)
            if as_json:
                print(json.dumps(data))
            else:
                print(f"Crawl {crawl_id}: {crawl_summary(data)} (timed out)")
            return 1
        print(f"  crawl {crawl_id}: {crawl_summary(data)}", file=sys.stderr)
        time.sleep(max(poll_every, 1))

    if as_json:
        print(json.dumps(data))
        return 0 if status == "completed" else 1

    if status != "completed":
        print(f"CRAWL FAILED for {url}: crawl {crawl_id} ended as "
              f"\"{status}\".", file=sys.stderr)
        print(json.dumps(data)[:800], file=sys.stderr)
        return 1

    credits = data.get("creditsUsed")
    suffix = f", {credits} credits used" if credits is not None else ""
    print(f"Crawl {crawl_id}: {crawl_summary(data)}{suffix}")
    print_pages(data, max_pages, max_chars)
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_CRAWL_PY
fi

# --- local-web-search/scripts/web_crawl_status.py ---
if [ -f "$SRC/local-web-search/scripts/web_crawl_status.py" ]; then
  cp "$SRC/local-web-search/scripts/web_crawl_status.py" "$TARGET/local-web-search/scripts/web_crawl_status.py"
else
  say "  [embedded] local-web-search/scripts/web_crawl_status.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_crawl_status.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_CRAWL_STATUS_PY'
#!/usr/bin/env python3
"""Get the status, progress, and available results of an existing Firecrawl
crawl (the firecrawl_check_crawl_status MCP tool).

Usage:
    python web_crawl_status.py <id> [--max-pages N] [--max-chars N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints `Crawl <id>: <status> (completed/total pages)`; when the crawl has
finished, the collected pages follow as `N. <url>` + markdown truncated at
--max-chars chars (default 2000; up to --max-pages pages, default 25).
`--json` prints the raw API response instead. The status query itself only
fails (exit 1) when the API cannot be reached; a `failed` crawl still exits 0.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal
import web_crawl  # sibling: shared crawl output formatting

ENDPOINT = fc.url("/v1/crawl")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_crawl_status.py <id> [--max-pages N] [--max-chars N] "
              "[--json]", file=sys.stderr)
        return 2
    crawl_id = args[0]
    max_pages, max_chars, as_json = 25, 2000, False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--max-pages" and i + 1 < len(args):
            i += 1
            try:
                max_pages = int(args[i])
            except ValueError:
                print(f"invalid --max-pages: {args[i]}", file=sys.stderr)
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

    try:
        data = fc.call("/v1/crawl/" + str(crawl_id), method="GET")
    except fc.FcError as e:
        print(f"CRAWL STATUS FAILED for {crawl_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    print(f"Crawl {crawl_id}: {web_crawl.crawl_summary(data)}")
    web_crawl.print_pages(data, max_pages, max_chars)
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_CRAWL_STATUS_PY
fi

# --- local-web-search/scripts/web_agent.py ---
if [ -f "$SRC/local-web-search/scripts/web_agent.py" ]; then
  cp "$SRC/local-web-search/scripts/web_agent.py" "$TARGET/local-web-search/scripts/web_agent.py"
else
  say "  [embedded] local-web-search/scripts/web_agent.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_agent.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_AGENT_PY'
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
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_AGENT_PY
fi

# --- local-web-search/scripts/web_agent_status.py ---
if [ -f "$SRC/local-web-search/scripts/web_agent_status.py" ]; then
  cp "$SRC/local-web-search/scripts/web_agent_status.py" "$TARGET/local-web-search/scripts/web_agent_status.py"
else
  say "  [embedded] local-web-search/scripts/web_agent_status.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_agent_status.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_AGENT_STATUS_PY'
#!/usr/bin/env python3
"""Get the progress or final results of a Firecrawl research agent job (the
firecrawl_agent_status MCP tool), started with web_agent.py.

Usage:
    python web_agent_status.py <id> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints `Agent <id>: <status>`. A `processing`/`active` status is non-terminal
— check again after 15-30 s. When the job is `completed`, the research result
follows (steps, sources, and the final answer/report as returned by the API);
`failed` jobs print the available error details and exit 1. `--json` prints
the raw API response instead.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/agent")


def print_result(result, indent=0):
    """Recursively print the agent result in a readable outline."""
    pad = " " * indent
    if isinstance(result, dict):
        for key, val in result.items():
            if isinstance(val, (dict, list)):
                print(f"{pad}{key}:")
                print_result(val, indent + 2)
            else:
                text = str(val)
                if len(text) > 4000:
                    text = text[:4000] + f"\n{pad}[... truncated ...]"
                print(f"{pad}{key}: {text}")
    elif isinstance(result, list):
        for n, item in enumerate(result, 1):
            print(f"{pad}{n}.")
            print_result(item, indent + 2)
    else:
        text = str(result)
        if len(text) > 4000:
            text = text[:4000] + f"\n{pad}[... truncated ...]"
        print(pad + text)


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_agent_status.py <id> [--json]", file=sys.stderr)
        return 2
    job_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/agent/" + str(job_id), method="GET")
    except fc.FcError as e:
        print(f"AGENT STATUS FAILED for {job_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0 if data.get("status") != "failed" else 1

    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    status = str(payload.get("status") or data.get("status") or "unknown")
    print(f"Agent {job_id}: {status}")
    if status not in ("completed", "failed", "cancelled", "stopped"):
        print("(non-terminal — check again after 15-30 s)")
        return 0
    result = payload.get("result")
    if result is None:
        result = data.get("result")
    if result is not None:
        print()
        print_result(result)
    elif status == "failed":
        error = payload.get("error") or data.get("error")
        print(f"error: {error or '(no details returned)'}")
    return 0 if status == "completed" else 1


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_AGENT_STATUS_PY
fi

# --- local-web-search/scripts/web_interact.py ---
if [ -f "$SRC/local-web-search/scripts/web_interact.py" ]; then
  cp "$SRC/local-web-search/scripts/web_interact.py" "$TARGET/local-web-search/scripts/web_interact.py"
else
  say "  [embedded] local-web-search/scripts/web_interact.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_interact.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_INTERACT_PY'
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
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_INTERACT_PY
fi

# --- local-web-search/scripts/web_interact_stop.py ---
if [ -f "$SRC/local-web-search/scripts/web_interact_stop.py" ]; then
  cp "$SRC/local-web-search/scripts/web_interact_stop.py" "$TARGET/local-web-search/scripts/web_interact_stop.py"
else
  say "  [embedded] local-web-search/scripts/web_interact_stop.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_interact_stop.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_INTERACT_STOP_PY'
#!/usr/bin/env python3
"""Stop the live Firecrawl interact session for a scrapeId and release its
resources (the firecrawl_interact_stop MCP tool).

Usage:
    python web_interact_stop.py <scrapeId> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints a confirmation (plus the API's response body when one is returned).
`--json` prints the raw API response instead. The session cannot be resumed
after it is stopped.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/interact")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_interact_stop.py <scrapeId> [--json]", file=sys.stderr)
        return 2
    scrape_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/interact/" + str(scrape_id) + "/stop",
                       method="POST")
    except fc.FcError as e:
        print(f"INTERACT STOP FAILED for {scrape_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(f"Interact session {scrape_id} stopped.")
    if data:
        print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_INTERACT_STOP_PY
fi

# --- local-web-search/scripts/web_parse.py ---
if [ -f "$SRC/local-web-search/scripts/web_parse.py" ]; then
  cp "$SRC/local-web-search/scripts/web_parse.py" "$TARGET/local-web-search/scripts/web_parse.py"
else
  say "  [embedded] local-web-search/scripts/web_parse.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_parse.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_PARSE_PY'
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
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_PARSE_PY
fi

# --- local-web-search/scripts/web_monitor_create.py ---
if [ -f "$SRC/local-web-search/scripts/web_monitor_create.py" ]; then
  cp "$SRC/local-web-search/scripts/web_monitor_create.py" "$TARGET/local-web-search/scripts/web_monitor_create.py"
else
  say "  [embedded] local-web-search/scripts/web_monitor_create.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_monitor_create.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CREATE_PY'
#!/usr/bin/env python3
"""Create a recurring Firecrawl monitor — a scrape, crawl, or search check
that compares each run with its retained predecessor (the
firecrawl_monitor_create MCP tool).

Usage:
    python web_monitor_create.py (--body '{...}' | --body-file monitor.json)
                                 [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

`--body` is the full monitor configuration as JSON (same object the MCP
tool's `body` parameter takes: name, schedule, goal, targets, webhook,
notification, retention, ...). `--body-file` reads it from a file instead.
Prints the created monitor as pretty JSON; `--json` prints the raw API
response instead.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def read_body_arg(args):
    """Return the monitor body as a dict from --body / --body-file, or
    (None, error-message)."""
    body_raw, body_file = None, None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--body" and i + 1 < len(args):
            i += 1
            body_raw = args[i]
        elif a == "--body-file" and i + 1 < len(args):
            i += 1
            body_file = args[i]
        i += 1
    if body_raw is not None and body_file is not None:
        return None, "provide either --body or --body-file, not both"
    if body_file is not None:
        try:
            with open(body_file, encoding="utf-8") as fh:
                body_raw = fh.read()
        except OSError as e:
            return None, "could not read {}: {}".format(body_file, e)
    if body_raw is None:
        return None, ("a monitor body is required: --body '{...}' "
                      "(full monitor JSON) or --body-file FILE")
    try:
        body = json.loads(body_raw)
    except ValueError as e:
        return None, "the body is not valid JSON: {}".format(e)
    if not isinstance(body, dict):
        return None, "the monitor body must be a JSON object"
    return body, None


def main() -> int:
    args = sys.argv[1:]
    as_json = "--json" in args
    body, err = read_body_arg(args)
    if err:
        print("usage: web_monitor_create.py (--body '{...}' | "
              "--body-file monitor.json) [--json]", file=sys.stderr)
        print(err, file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/monitor", method="POST", body=body)
    except fc.FcError as e:
        print(f"MONITOR CREATE FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CREATE_PY
fi

# --- local-web-search/scripts/web_monitor_list.py ---
if [ -f "$SRC/local-web-search/scripts/web_monitor_list.py" ]; then
  cp "$SRC/local-web-search/scripts/web_monitor_list.py" "$TARGET/local-web-search/scripts/web_monitor_list.py"
else
  say "  [embedded] local-web-search/scripts/web_monitor_list.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_monitor_list.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_LIST_PY'
#!/usr/bin/env python3
"""List the Firecrawl monitors of the authenticated account (the
firecrawl_monitor_list MCP tool), with optional pagination.

Usage:
    python web_monitor_list.py [--limit N] [--offset N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints one line per monitor: `N. <id> — <name> (<state>)`. `--json` prints
the raw API response instead.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = sys.argv[1:]
    limit, offset, as_json = None, None, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--limit" and i + 1 < len(args):
            i += 1
            try:
                limit = int(args[i])
            except ValueError:
                print(f"invalid --limit: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--offset" and i + 1 < len(args):
            i += 1
            try:
                offset = int(args[i])
            except ValueError:
                print(f"invalid --offset: {args[i]}", file=sys.stderr)
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

    query = {}
    if limit is not None:
        query["limit"] = limit
    if offset is not None:
        query["offset"] = offset

    try:
        data = fc.call("/v1/monitor", method="GET", query=query)
    except fc.FcError as e:
        print(f"MONITOR LIST FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    monitors = data.get("monitors")
    if not isinstance(monitors, list):
        monitors = data.get("data")
    if not isinstance(monitors, list):
        monitors = data if isinstance(data, list) else []
    if not monitors:
        print("(no monitors)")
        return 0
    for n, monitor in enumerate(monitors, 1):
        if not isinstance(monitor, dict):
            print(f"{n}. {monitor}")
            continue
        mid = monitor.get("id") or monitor.get("monitorId") or "?"
        name = monitor.get("name") or "(unnamed)"
        state = (monitor.get("state") or monitor.get("status")
                 or ("active" if monitor.get("active") else "paused"))
        print(f"{n}. {mid} — {name} ({state})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_LIST_PY
fi

# --- local-web-search/scripts/web_monitor_get.py ---
if [ -f "$SRC/local-web-search/scripts/web_monitor_get.py" ]; then
  cp "$SRC/local-web-search/scripts/web_monitor_get.py" "$TARGET/local-web-search/scripts/web_monitor_get.py"
else
  say "  [embedded] local-web-search/scripts/web_monitor_get.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_monitor_get.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_GET_PY'
#!/usr/bin/env python3
"""Retrieve one Firecrawl monitor by ID, including its configuration and
current state (the firecrawl_monitor_get MCP tool).

Usage:
    python web_monitor_get.py <id> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the monitor as pretty JSON. `--json` prints the raw API response
instead. This does not run or modify the monitor.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_monitor_get.py <id> [--json]", file=sys.stderr)
        return 2
    monitor_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id), method="GET")
    except fc.FcError as e:
        print(f"MONITOR GET FAILED for {monitor_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_GET_PY
fi

# --- local-web-search/scripts/web_monitor_update.py ---
if [ -f "$SRC/local-web-search/scripts/web_monitor_update.py" ]; then
  cp "$SRC/local-web-search/scripts/web_monitor_update.py" "$TARGET/local-web-search/scripts/web_monitor_update.py"
else
  say "  [embedded] local-web-search/scripts/web_monitor_update.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_monitor_update.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_UPDATE_PY'
#!/usr/bin/env python3
"""Patch an existing Firecrawl monitor by ID (the firecrawl_monitor_update
MCP tool): change its name, active/paused status, schedule, targets, goal,
judging, webhook, notifications, or retention — these changes affect future
scheduled checks.

Usage:
    python web_monitor_update.py <id> (--body '{...}' | --body-file patch.json)
                                  [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

`--body` is the patch as JSON (same object the MCP tool's `body` parameter
takes); `--body-file` reads it from a file instead. Prints the updated
monitor as pretty JSON; `--json` prints the raw API response instead.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal
import web_monitor_create  # sibling: shared --body / --body-file reading

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_monitor_update.py <id> (--body '{...}' | "
              "--body-file patch.json) [--json]", file=sys.stderr)
        return 2
    monitor_id = args[0]
    as_json = "--json" in args
    body, err = web_monitor_create.read_body_arg(args)
    if err:
        print(err, file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id), method="PATCH",
                       body=body)
    except fc.FcError as e:
        print(f"MONITOR UPDATE FAILED for {monitor_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_UPDATE_PY
fi

# --- local-web-search/scripts/web_monitor_delete.py ---
if [ -f "$SRC/local-web-search/scripts/web_monitor_delete.py" ]; then
  cp "$SRC/local-web-search/scripts/web_monitor_delete.py" "$TARGET/local-web-search/scripts/web_monitor_delete.py"
else
  say "  [embedded] local-web-search/scripts/web_monitor_delete.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_monitor_delete.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_DELETE_PY'
#!/usr/bin/env python3
"""Permanently delete a Firecrawl monitor by ID and stop its future schedule
(the firecrawl_monitor_delete MCP tool). This cannot be undone.

Usage:
    python web_monitor_delete.py <id> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints a confirmation (plus the API's response body when one is returned).
`--json` prints the raw API response instead.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_monitor_delete.py <id> [--json]", file=sys.stderr)
        return 2
    monitor_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id), method="DELETE")
    except fc.FcError as e:
        print(f"MONITOR DELETE FAILED for {monitor_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(f"Monitor {monitor_id} deleted.")
    if data:
        print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_DELETE_PY
fi

# --- local-web-search/scripts/web_monitor_run.py ---
if [ -f "$SRC/local-web-search/scripts/web_monitor_run.py" ]; then
  cp "$SRC/local-web-search/scripts/web_monitor_run.py" "$TARGET/local-web-search/scripts/web_monitor_run.py"
else
  say "  [embedded] local-web-search/scripts/web_monitor_run.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_monitor_run.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_RUN_PY'
#!/usr/bin/env python3
"""Queue an immediate check for a Firecrawl monitor, outside its normal
schedule (the firecrawl_monitor_run MCP tool).

Usage:
    python web_monitor_run.py <id> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the queued check as pretty JSON. `--json` prints the raw API response
instead. Follow the check with web_monitor_checks.py / web_monitor_check.py.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_monitor_run.py <id> [--json]", file=sys.stderr)
        return 2
    monitor_id = args[0]
    as_json = "--json" in args[1:]

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id) + "/run",
                       method="POST")
    except fc.FcError as e:
        print(f"MONITOR RUN FAILED for {monitor_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_RUN_PY
fi

# --- local-web-search/scripts/web_monitor_checks.py ---
if [ -f "$SRC/local-web-search/scripts/web_monitor_checks.py" ]; then
  cp "$SRC/local-web-search/scripts/web_monitor_checks.py" "$TARGET/local-web-search/scripts/web_monitor_checks.py"
else
  say "  [embedded] local-web-search/scripts/web_monitor_checks.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_monitor_checks.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CHECKS_PY'
#!/usr/bin/env python3
"""List the historical checks of a Firecrawl monitor (the
firecrawl_monitor_checks MCP tool), optionally filtered by status and
paginated.

Usage:
    python web_monitor_checks.py <id> [--status queued|running|completed|failed|partial]
                                 [--limit N] [--offset N] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints one line per check: `N. <checkId> <status> <createdAt>`. `--json`
prints the raw API response instead. Read one check's page-level results
with web_monitor_check.py.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")

STATUSES = ("queued", "running", "completed", "failed", "partial")


def main() -> int:
    args = sys.argv[1:]
    if not args or args[0].startswith("--"):
        print("usage: web_monitor_checks.py <id> "
              "[--status queued|running|completed|failed|partial] "
              "[--limit N] [--offset N] [--json]", file=sys.stderr)
        return 2
    monitor_id = args[0]
    status, limit, offset, as_json = None, None, None, False
    i = 1
    while i < len(args):
        a = args[i]
        if a == "--status" and i + 1 < len(args):
            i += 1
            status = args[i]
            if status not in STATUSES:
                print(f"invalid --status: {status} "
                      f"(one of {', '.join(STATUSES)})", file=sys.stderr)
                return 2
        elif a == "--limit" and i + 1 < len(args):
            i += 1
            try:
                limit = int(args[i])
            except ValueError:
                print(f"invalid --limit: {args[i]}", file=sys.stderr)
                return 2
        elif a == "--offset" and i + 1 < len(args):
            i += 1
            try:
                offset = int(args[i])
            except ValueError:
                print(f"invalid --offset: {args[i]}", file=sys.stderr)
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

    query = {}
    if status is not None:
        query["status"] = status
    if limit is not None:
        query["limit"] = limit
    if offset is not None:
        query["offset"] = offset

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id) + "/checks",
                       method="GET", query=query)
    except fc.FcError as e:
        print(f"MONITOR CHECKS FAILED for {monitor_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    checks = data.get("checks")
    if not isinstance(checks, list):
        checks = data.get("data")
    if not isinstance(checks, list):
        checks = data if isinstance(data, list) else []
    if not checks:
        print("(no checks)")
        return 0
    for n, check in enumerate(checks, 1):
        if not isinstance(check, dict):
            print(f"{n}. {check}")
            continue
        cid = check.get("id") or check.get("checkId") or "?"
        cstatus = check.get("status") or "?"
        when = (check.get("createdAt") or check.get("startedAt")
                or check.get("completedAt") or "")
        print(f"{n}. {cid} {cstatus} {when}".rstrip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CHECKS_PY
fi

# --- local-web-search/scripts/web_monitor_check.py ---
if [ -f "$SRC/local-web-search/scripts/web_monitor_check.py" ]; then
  cp "$SRC/local-web-search/scripts/web_monitor_check.py" "$TARGET/local-web-search/scripts/web_monitor_check.py"
else
  say "  [embedded] local-web-search/scripts/web_monitor_check.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_monitor_check.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CHECK_PY'
#!/usr/bin/env python3
"""Retrieve one Firecrawl monitor check and its page-level results (the
firecrawl_monitor_check MCP tool). Pages report `same`, `new`, `changed`,
`removed`, or `error`; goal judging adds a meaningful-change decision.
Markdown tracking returns a unified text diff; JSON tracking returns field
paths with previous/current values.

Usage:
    python web_monitor_check.py <id> <checkId> [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the check (configuration, page results, diffs) as pretty JSON.
`--json` prints the raw API response instead.

NOTE: monitors are a Firecrawl ACCOUNT feature — they need an API key (set
FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for the
cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/monitor")


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    if len(args) != 2 or args[0].startswith("--") or args[1].startswith("--"):
        print("usage: web_monitor_check.py <id> <checkId> [--json]",
              file=sys.stderr)
        return 2
    monitor_id, check_id = args

    try:
        data = fc.call("/v1/monitor/" + str(monitor_id) + "/checks/"
                       + str(check_id), method="GET")
    except fc.FcError as e:
        print(f"MONITOR CHECK FAILED for {monitor_id}/{check_id}: {e}",
              file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_MONITOR_CHECK_PY
fi

# --- local-web-search/scripts/web_research_search.py ---
if [ -f "$SRC/local-web-search/scripts/web_research_search.py" ]; then
  cp "$SRC/local-web-search/scripts/web_research_search.py" "$TARGET/local-web-search/scripts/web_research_search.py"
else
  say "  [embedded] local-web-search/scripts/web_research_search.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_research_search.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_SEARCH_PY'
#!/usr/bin/env python3
"""Search research papers via the Firecrawl research index (the
firecrawl_research_search_papers MCP tool): paper metadata and abstracts
across biomedical, life-science, and clinical literature (PubMed, bioRxiv,
medRxiv) alongside arXiv and other scientific sources.

Usage:
    python web_research_search.py "<query>" [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the ranked papers exactly like the MCP tool does — for each paper:

    ## [paperId] title
    Authors: name; name; +N more
    abstract (up to 600 chars)

Several distinct framings of the same question surface different papers.
Inspect one paper with web_research_inspect.py. `--json` prints the raw API
response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/research/search/papers")

MAX_AUTHORS = 15
MAX_ABSTRACT_CHARS = 600
MAX_AFFIL_CHARS = 60
MAX_AUTHORS_LINE_CHARS = 400


def display_id(paper):
    return paper.get("primaryId") or paper.get("paperId") or "missing-primary-id"


def fmt_authors(authors):
    """`Authors: a; b (affiliation); +N more` or None (mirrors the MCP tool)."""
    if not authors:
        return None
    if isinstance(authors, str):
        names = [s.strip() for s in authors.split(",") if s.strip()]
        if not names:
            return None
        total, shown = len(names), names[:MAX_AUTHORS]
    else:
        if not isinstance(authors, list) or not authors:
            return None
        total = len(authors)
        shown = []
        for a in authors[:MAX_AUTHORS]:
            if isinstance(a, dict):
                aff = (a.get("affiliation") or "").strip()
                name = a.get("name") or "?"
                shown.append("{} ({})".format(name, aff[:MAX_AFFIL_CHARS])
                             if aff else name)
            else:
                shown.append(str(a))
    extra = "; +{} more".format(total - MAX_AUTHORS) if total > MAX_AUTHORS \
        else ""
    return ("Authors: " + "; ".join(shown) + extra)[:MAX_AUTHORS_LINE_CHARS]


def fmt_hits(results):
    """Format ranked paper results (mirrors the MCP tool's formatter)."""
    if not results:
        return "(no results)"
    blocks = []
    for r in results:
        if not isinstance(r, dict):
            blocks.append(str(r))
            continue
        lines = ["## [{}] {}".format(display_id(r),
                                     r.get("title") or "(untitled)")]
        authors = fmt_authors(r.get("authors"))
        if authors:
            lines.append(authors)
        abstract = (r.get("abstract") or "(no abstract)")
        abstract = " ".join(abstract.split())[:MAX_ABSTRACT_CHARS]
        lines.append(abstract)
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def extract_results(data):
    """Find the paper-result list in the API response."""
    results = data.get("results")
    if isinstance(results, list):
        return results
    payload = data.get("data")
    if isinstance(payload, dict) and isinstance(payload.get("results"), list):
        return payload["results"]
    if isinstance(data, list):
        return data
    return []


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    query = " ".join(args).strip()
    if not query:
        print('usage: web_research_search.py "<query>" [--json]', file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/research/search/papers", method="POST",
                       body={"query": query})
    except fc.FcError as e:
        print(f"RESEARCH SEARCH FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(fmt_hits(extract_results(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_SEARCH_PY
fi

# --- local-web-search/scripts/web_research_inspect.py ---
if [ -f "$SRC/local-web-search/scripts/web_research_inspect.py" ]; then
  cp "$SRC/local-web-search/scripts/web_research_inspect.py" "$TARGET/local-web-search/scripts/web_research_inspect.py"
else
  say "  [embedded] local-web-search/scripts/web_research_inspect.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_research_inspect.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_INSPECT_PY'
#!/usr/bin/env python3
"""Inspect one research paper via the Firecrawl research index (the
firecrawl_research_inspect_paper MCP tool): canonical metadata for a paper
ID such as an arXiv, PMC, PMID, or DOI identifier.

Usage:
    python web_research_inspect.py <paperId> [--json]

Examples:
    python web_research_inspect.py arxiv:1706.03762
    python web_research_inspect.py doi:10.1016/j.neunet.2025.108095

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the paper's metadata exactly like the MCP tool does:

    # title
    Paper ID: ...
    IDs: namespace:value, ...
    Authors: ...
    Categories: ...
    Dates: created ...; updated ...
    ## Abstract
    ...

Find papers to inspect with web_research_search.py. `--json` prints the raw
API response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal
import web_research_search  # sibling: shared paper formatters

ENDPOINT = fc.url("/v1/research/papers")


def fmt_paper_metadata(paper):
    """Format one paper's metadata (mirrors the MCP tool's formatter)."""
    if not paper:
        return "(paper not found)"
    lines = ["# " + (paper.get("title") or "(untitled)"), ""]
    lines.append("Paper ID: {}".format(paper.get("paperId") or "?"))
    ids = []
    for namespace, values in (paper.get("ids") or {}).items():
        if isinstance(values, list):
            ids.extend("{}:{}".format(namespace, v) for v in values)
        elif values is not None:
            ids.append("{}:{}".format(namespace, values))
    if ids:
        lines.append("IDs: " + ", ".join(ids))
    authors = web_research_search.fmt_authors(paper.get("authors"))
    if authors:
        lines.append(authors)
    categories = paper.get("categories")
    if isinstance(categories, list) and categories:
        lines.append("Categories: " + ", ".join(str(c) for c in categories))
    dates = []
    if paper.get("createdDate"):
        dates.append("created " + str(paper["createdDate"]))
    if paper.get("updateDate"):
        dates.append("updated " + str(paper["updateDate"]))
    if dates:
        lines.append("Dates: " + "; ".join(dates))
    lines.append("")
    lines.append("## Abstract")
    lines.append(" ".join((paper.get("abstract") or "(no abstract)").split()))
    return "\n".join(lines)


def extract_paper(data):
    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    paper = payload.get("paper")
    if isinstance(paper, dict):
        return paper
    if isinstance(payload, dict) and (payload.get("paperId") or payload.get("title")):
        return payload
    return None


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    if len(args) != 1 or args[0].startswith("--"):
        print("usage: web_research_inspect.py <paperId> [--json]", file=sys.stderr)
        return 2
    paper_id = args[0]

    path = "/v1/research/papers/" + urllib.parse.quote(paper_id, safe="")
    try:
        data = fc.call(path, method="GET")
    except fc.FcError as e:
        print(f"RESEARCH INSPECT FAILED for {paper_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    print(fmt_paper_metadata(extract_paper(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_INSPECT_PY
fi

# --- local-web-search/scripts/web_research_related.py ---
if [ -f "$SRC/local-web-search/scripts/web_research_related.py" ]; then
  cp "$SRC/local-web-search/scripts/web_research_related.py" "$TARGET/local-web-search/scripts/web_research_related.py"
else
  say "  [embedded] local-web-search/scripts/web_research_related.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_research_related.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_RELATED_PY'
#!/usr/bin/env python3
"""Find research papers related to seed papers via the Firecrawl citation
graph (the firecrawl_research_related_papers MCP tool).

Usage:
    python web_research_related.py <seedId> [seedId ...] --intent "what to rank for"
                                   [--mode similar|citers|references] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

One to ten seed paper IDs (positional); the first is the primary seed, the
rest are anchors. `--intent` (required) is a short natural-language
description that ranks the candidates. `--mode` defaults to `similar`
(co-citation / bibliographic coupling); `citers` returns papers citing a
seed, `references` papers cited by a seed.

Prints the ranked candidates like web_research_search.py, then
`(poolSize=N)` and any `note:` from the API. `--json` prints the raw API
response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal
import web_research_search  # sibling: shared paper formatters

ENDPOINT = fc.url("/v1/research/related")

MODES = ("similar", "citers", "references")


def main() -> int:
    args = sys.argv[1:]
    seeds, intent, mode, as_json = [], None, None, False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--intent" and i + 1 < len(args):
            i += 1
            intent = args[i]
        elif a == "--mode" and i + 1 < len(args):
            i += 1
            mode = args[i]
            if mode not in MODES:
                print(f"invalid --mode: {mode} (one of {', '.join(MODES)})",
                      file=sys.stderr)
                return 2
        elif a == "--json":
            as_json = True
        elif a.startswith("--"):
            print(f"unknown option: {a}", file=sys.stderr)
            return 2
        else:
            seeds.append(a)
        i += 1

    if not seeds or not intent:
        print('usage: web_research_related.py <seedId> [seedId ...] '
              '--intent "what to rank for" '
              '[--mode similar|citers|references] [--json]', file=sys.stderr)
        return 2
    if not 1 <= len(seeds) <= 10:
        print("provide one to ten seed paper IDs (first is the primary seed)",
              file=sys.stderr)
        return 2

    body = {"seed_ids": seeds, "intent": intent}
    if mode:
        body["mode"] = mode

    try:
        data = fc.call("/v1/research/related", method="POST", body=body)
    except fc.FcError as e:
        print(f"RESEARCH RELATED FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    payload = data.get("data") if isinstance(data.get("data"), dict) else data
    print(web_research_search.fmt_hits(
        web_research_search.extract_results(data)))
    pool_size = payload.get("poolSize") or 0
    print(f"(poolSize={pool_size})")
    note = payload.get("note")
    if note:
        print(f"note: {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_RELATED_PY
fi

# --- local-web-search/scripts/web_research_read.py ---
if [ -f "$SRC/local-web-search/scripts/web_research_read.py" ]; then
  cp "$SRC/local-web-search/scripts/web_research_read.py" "$TARGET/local-web-search/scripts/web_research_read.py"
else
  say "  [embedded] local-web-search/scripts/web_research_read.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_research_read.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_READ_PY'
#!/usr/bin/env python3
"""Read in-body passages from one research paper that are relevant to a
specific question (the firecrawl_research_read_paper MCP tool). Full text is
available only for indexed papers.

Usage:
    python web_research_read.py <paperId> "<question>" [--json]

Example:
    python web_research_read.py arxiv:1706.03762 "how is attention computed?"

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the matching passages separated by `---` lines (like the MCP tool), or
a notice when no full text is available. `--json` prints the raw API
response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/research/papers")


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    if len(args) != 2 or args[0].startswith("--") or args[1].startswith("--"):
        print('usage: web_research_read.py <paperId> "<question>" [--json]',
              file=sys.stderr)
        return 2
    paper_id, question = args

    path = ("/v1/research/papers/" + urllib.parse.quote(paper_id, safe="")
            + "/read")
    try:
        data = fc.call(path, method="POST", body={"question": question})
    except fc.FcError as e:
        print(f"RESEARCH READ FAILED for {paper_id}: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0

    passages = data.get("passages")
    if passages is None:
        payload = data.get("data") if isinstance(data.get("data"), dict) \
            else data
        passages = payload.get("passages")
    if not isinstance(passages, list) or not passages:
        print("(no full-text passages available for this paper)")
        return 0
    texts = [p.get("text") if isinstance(p, dict) else str(p)
             for p in passages]
    print("\n---\n".join(t for t in texts if t))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_RESEARCH_READ_PY
fi

# --- local-web-search/scripts/web_github_search.py ---
if [ -f "$SRC/local-web-search/scripts/web_github_search.py" ]; then
  cp "$SRC/local-web-search/scripts/web_github_search.py" "$TARGET/local-web-search/scripts/web_github_search.py"
else
  say "  [embedded] local-web-search/scripts/web_github_search.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_github_search.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_GITHUB_SEARCH_PY'
#!/usr/bin/env python3
"""Search indexed public GitHub issue, pull-request, and README content via
the Firecrawl research index (the firecrawl_research_search_github MCP
tool).

Usage:
    python web_github_search.py "<query>" [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Prints the ranked matches exactly like the MCP tool does — for each hit:

    [repo#123] (pull_request, 5 segments)
    https://github.com/...
    matched content (up to 1200 chars)

`--json` prints the raw API response instead.

NOTE: research tools need a Firecrawl account with research permissions
(set FIRECRAWL_API_KEY, and FIRECRAWL_API_URL=https://api.firecrawl.dev for
the cloud API); the self-hosted stack may not expose them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/research/search/github")

MAX_CONTENT_CHARS = 1200


def fmt_github(results):
    """Format ranked GitHub matches (mirrors the MCP tool's formatter)."""
    if not results:
        return "(no results)"
    blocks = []
    for r in results:
        if not isinstance(r, dict):
            blocks.append(str(r))
            continue
        lines = []
        repo = r.get("repo") or "?"
        number = r.get("number")
        if number is None and r.get("pageType") is None:
            lines.append(f"[{repo}] README")
        else:
            ref = f"#{number}" if number is not None else ""
            meta_parts = [str(r.get("pageType") or "")]
            if r.get("segmentCount"):
                meta_parts.append(f"{r['segmentCount']} segments")
            meta = ", ".join(p for p in meta_parts if p)
            lines.append(f"[{repo}{ref}]" + (f" ({meta})" if meta else ""))
        url = r.get("readmeUrl") or r.get("url")
        if url:
            lines.append(url)
        body = (r.get("contentMd") or r.get("snippet") or "").strip()
        lines.append(body[:MAX_CONTENT_CHARS] if body else "(no content)")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv[1:]
    query = " ".join(args).strip()
    if not query:
        print('usage: web_github_search.py "<query>" [--json]', file=sys.stderr)
        return 2

    try:
        data = fc.call("/v1/research/search/github", method="POST",
                       body={"query": query})
    except fc.FcError as e:
        print(f"GITHUB SEARCH FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    results = data.get("results")
    if results is None:
        payload = data.get("data") if isinstance(data.get("data"), dict) \
            else data
        results = payload.get("results")
    if not isinstance(results, list):
        results = []
    print(fmt_github(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_GITHUB_SEARCH_PY
fi

# --- local-web-search/scripts/web_developer_search.py ---
if [ -f "$SRC/local-web-search/scripts/web_developer_search.py" ]; then
  cp "$SRC/local-web-search/scripts/web_developer_search.py" "$TARGET/local-web-search/scripts/web_developer_search.py"
else
  say "  [embedded] local-web-search/scripts/web_developer_search.py  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/local-web-search/scripts/web_developer_search.py" <<'EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_DEVELOPER_SEARCH_PY'
#!/usr/bin/env python3
"""Search the Firecrawl developer index — built for coding agents, covering
GitHub issues, merged pull requests, repository READMEs, and curated
documentation sites (the firecrawl_developer_search MCP tool).

Usage:
    python web_developer_search.py "<query>" [--skills-only] [--json]

Self-healing: if the local-search stack is unreachable (Docker engine or the
containers are down), this script automatically starts them (the same logic
as ensure_stack.py / Run.bat) and retries the request. Connection failures
self-heal once; transient 429/5xx answers are retried with a short backoff.
You do NOT need to run ensure_stack.py first — just run the script.

Use it for developer questions — code behaviour, a library or framework, an
API contract, an error message, or a known bug. `--skills-only` limits the
search to agent-skill files. Prints the ranked results exactly like the MCP
tool does — for each hit:

    ## [id] (kind) title
    https://...
    matched passages (up to 1200 chars, separated by ---)

`--json` prints the raw API response instead.

NOTE: developer search needs a Firecrawl account with developer-search
permissions (set FIRECRAWL_API_KEY, and
FIRECRAWL_API_URL=https://api.firecrawl.dev for the cloud API); the
self-hosted stack may not expose it.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firecrawl_api as fc  # sibling: Firecrawl HTTP client + self-heal

ENDPOINT = fc.url("/v1/developer/search")

MAX_PASSAGE_CHARS = 1200


def fmt_developer(results):
    """Format ranked developer-index results (mirrors the MCP formatter)."""
    if not results:
        return "(no results)"
    blocks = []
    for r in results:
        if not isinstance(r, dict):
            blocks.append(str(r))
            continue
        rid = r.get("id") or "?"
        kind = str(rid).split(":", 1)[0]
        lines = ["## [{}]{} {}".format(rid, f" ({kind})" if kind else "",
                                       r.get("title") or "(untitled)")]
        if r.get("url"):
            lines.append(r["url"])
        passages = r.get("passages")
        body = ""
        if isinstance(passages, list):
            body = "\n---\n".join((p.get("text") or "")
                                  if isinstance(p, dict) else str(p)
                                  for p in passages).strip()
        lines.append(body[:MAX_PASSAGE_CHARS] if body else "(no content)")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--json" and a != "--skills-only"]
    as_json = "--json" in sys.argv[1:]
    skills_only = "--skills-only" in sys.argv[1:]
    query = " ".join(args).strip()
    if not query:
        print('usage: web_developer_search.py "<query>" [--skills-only] [--json]',
              file=sys.stderr)
        return 2

    body = {"query": query}
    if skills_only:
        body["skills"] = "only"

    try:
        data = fc.call("/v1/developer/search", method="POST", body=body)
    except fc.FcError as e:
        print(f"DEVELOPER SEARCH FAILED: {e}", file=sys.stderr)
        if e.hint:
            print(e.hint, file=sys.stderr)
        return 1

    if as_json:
        print(json.dumps(data))
        return 0
    results = data.get("results")
    if results is None:
        payload = data.get("data") if isinstance(data.get("data"), dict) \
            else data
        results = payload.get("results") or payload.get("developer")
    if not isinstance(results, list):
        results = []
    print(fmt_developer(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF_LOCAL_WEB_SEARCH_SCRIPTS_WEB_DEVELOPER_SEARCH_PY
fi

# --- install-local-search.bat ---
if [ -f "$SRC/install-local-search.bat" ]; then
  cp "$SRC/install-local-search.bat" "$TARGET/install-local-search.bat"
else
  say "  [embedded] install-local-search.bat  (source not found next to installer; using built-in copy)"
  cat > "$TARGET/install-local-search.bat" <<'EOF_INSTALL_LOCAL_SEARCH_BAT'
@echo off
setlocal enableDelayedExpansion
title Local Search - Installer
REM  Prompts run on a code page other than 65001: while the console is on 65001
REM  (UTF-8), set /p returns an empty line for redirected or piped stdin, so
REM  scripted answers are lost. The code page the console started on is used, or
REM  437 when it is already 65001 (chcp persists after a script ends). UTF-8 is
REM  enabled after the last prompt.
set "LS_PROMPT_CP=437"
for /f "tokens=2 delims=:" %%c in ('chcp') do for /f %%n in ("%%c") do set "LS_PROMPT_CP=%%n"
if "!LS_PROMPT_CP!"=="65001" set "LS_PROMPT_CP=437"
chcp !LS_PROMPT_CP! >nul 2>&1

REM ===========================================================================
REM  Local Search Installer  (Firecrawl + SearXNG + local-web-search skill)  -  Windows
REM ===========================================================================
REM  Self-contained: every file the installer needs is embedded below as
REM  base64. If a source file is missing from this script's folder (e.g. you
REM  only downloaded this one .bat), the embedded copy is used instead.
REM  After installing the stack it also copies the bundled local-web-search agent
REM  skill into %USERPROFILE%\.agents\skills\local-web-search.
REM  It also asks which browser rendering engine Firecrawl should use -
REM  Playwright (default) or Browserless (stealth mode, better block
REM  avoidance) - and writes COMPOSE_PROFILES so only that one starts.
REM  The installer asks a y/N "Add a Firecrawl account?" question (default N):
REM  without an account only the free local skill tools are installed (the
REM  19 account-gated scripts are skipped and a core-only SKILL.md is used);
REM  with one the credentials are written to .env and all 25 tools install (26 with an LLM).
REM  If the Docker engine is not running, the installer launches Docker
REM  Desktop automatically and waits for it before pulling images.
REM ===========================================================================

echo ============================================================
echo   Local Search Installer  (Firecrawl + SearXNG + local-web-search)
echo   A local web-browsing system for AI models.
echo ============================================================
echo.

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker was not found on your PATH.
  echo   Install Docker Desktop: https://www.docker.com/products/docker-desktop/
  echo   Then re-run this installer.
  pause & exit /b 1
)
docker info >nul 2>&1
if not errorlevel 1 goto docker_ok
echo [NOTE] The Docker engine is not running - trying to start Docker Desktop...
set "DD_EXE="
if exist "%ProgramFiles%\Docker\Docker\Docker Desktop.exe" set "DD_EXE=%ProgramFiles%\Docker\Docker\Docker Desktop.exe"
if not defined DD_EXE if exist "%ProgramFiles(x86)%\Docker\Docker\Docker Desktop.exe" set "DD_EXE=%ProgramFiles(x86)%\Docker\Docker\Docker Desktop.exe"
if not defined DD_EXE if exist "%LOCALAPPDATA%\Programs\Docker Desktop\Docker Desktop.exe" set "DD_EXE=%LOCALAPPDATA%\Programs\Docker Desktop\Docker Desktop.exe"
if not defined DD_EXE (
  echo [ERROR] Docker Desktop was not found in the usual install locations.
  echo   Start it manually, wait until it says "running", then re-run
  echo   this installer.
  pause & exit /b 1
)
echo     Launching: "!DD_EXE!"
start "" "!DD_EXE!"
set "DD_LAUNCHED=1"
echo     Docker Desktop is starting in the background. Answer the next
echo     questions while it boots - the installer waits for the engine
echo     before pulling images.
:docker_ok
if not defined DD_LAUNCHED echo [OK] Docker is running.
echo.

set "SRC=%~dp0"
if "!SRC:~-1!"=="\" set "SRC=!SRC:~0,-1!"

set "DEFAULT_TARGET=%USERPROFILE%\local-search"

echo ============================================================
echo   Setup type
echo ============================================================
echo   1) Minimal installation
echo   2) Minimal + LLM Extraction
echo   3) Full installation
echo   Options 1 and 2 use: %DEFAULT_TARGET%, SearXNG 9990, Firecrawl 9991,
echo   Playwright engine, no Firecrawl account. Option 2 also asks for an LLM.
echo   You can change any of this later by editing .env and running
echo   Update.bat.
:ask_setup_type
set "SETUP_MODE="
set /p SETUP_MODE="  Choose 1, 2 or 3 [Enter = 1]: "
if not defined SETUP_MODE set "SETUP_MODE=1"
if "!SETUP_MODE!"=="3" goto full_setup
if "!SETUP_MODE!"=="1" goto defaults_chosen
if "!SETUP_MODE!"=="2" goto defaults_chosen
echo   Please enter 1, 2 or 3.
goto ask_setup_type
:defaults_chosen

set "TARGET=%DEFAULT_TARGET%"
for %%I in ("!TARGET!") do set "TARGET=%%~fI"
set "SEARXNG_PORT=9990"
set "FIRECRAWL_PORT=9991"
set "BROWSER_ENGINE=playwright"
set "PW_URL=http://playwright-service:3000/scrape"
set "OPENAI_BASE_URL="
set "OPENAI_API_KEY="
set "MODEL_NAME="
set "FC_API_KEY="
set "FC_API_URL="
if not "!SETUP_MODE!"=="2" goto defaults_applied
echo.
echo --- LLM extraction ---------------------------------------
call :llm_intro
call :ask_llm
:defaults_applied
echo   Using defaults - see summary below.
echo.
goto setup_done

:full_setup
echo --- Step 1 of 6: Install location --------------------------
echo   Default: %DEFAULT_TARGET%
set "TARGET="
set /p TARGET="  Target folder [press Enter for default]: "
if "!TARGET!"=="" set "TARGET=%DEFAULT_TARGET%"
set "TARGET=!TARGET:"=!"
for %%I in ("!TARGET!") do set "TARGET=%%~fI"
echo   Using: !TARGET!
echo.

:ask_searxng
echo --- Step 2 of 6: SearXNG port (default 9990) --------------
set "SEARXNG_PORT="
set /p SEARXNG_PORT="  Port for SearXNG [press Enter for 9990]: "
if "!SEARXNG_PORT!"=="" set "SEARXNG_PORT=9990"
call :validate_port "!SEARXNG_PORT!"
if !errorlevel! neq 0 ( echo   [WARNING] "!SEARXNG_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_searxng )

:ask_firecrawl
echo --- Step 3 of 6: Firecrawl port (default 9991) ------------
set "FIRECRAWL_PORT="
set /p FIRECRAWL_PORT="  Port for Firecrawl [press Enter for 9991]: "
if "!FIRECRAWL_PORT!"=="" set "FIRECRAWL_PORT=9991"
call :validate_port "!FIRECRAWL_PORT!"
if !errorlevel! neq 0 ( echo   [WARNING] "!FIRECRAWL_PORT!" is not a valid port ^(1-65535^). & echo. & goto ask_firecrawl )
if /i "!FIRECRAWL_PORT!"=="!SEARXNG_PORT!" ( echo   [WARNING] Firecrawl port must differ from SearXNG port. & echo. & goto ask_firecrawl )

echo.
echo --- Step 4 of 6: Browser rendering engine (default: Playwright) ---
echo   Firecrawl needs a headless-browser service for JS-rendered pages.
echo   Playwright  - the classic Firecrawl engine ^(default^).
echo   Browserless - stealth mode ^(masks automation fingerprints^);
echo                 better at avoiding Cloudflare/bot-check blocks.
set "USE_BROWSERLESS="
set /p USE_BROWSERLESS="  Use Browserless instead of Playwright? [y/N]: "
if /i "!USE_BROWSERLESS!"=="y" (
  set "BROWSER_ENGINE=browserless"
  set "PW_URL=http://browserless:3000/scrape"
) else (
  set "BROWSER_ENGINE=playwright"
  set "PW_URL=http://playwright-service:3000/scrape"
)
echo     ^(Engine: !BROWSER_ENGINE!^)

echo.
echo --- Step 5 of 6: LLM (optional) ---------------------
call :llm_intro
set "USE_LLM="
set /p USE_LLM="  Connect LLM now? [y/N]: "
set "OPENAI_BASE_URL="
set "OPENAI_API_KEY="
set "MODEL_NAME="
if /i not "!USE_LLM!"=="y" goto llm_done
call :ask_llm
:llm_done

echo --- Step 6 of 6: Firecrawl account (optional) -------------
echo   The extra tools ^(research agent, live-page interact, file parse,
echo   monitors, paper research, GitHub/developer search^) only work
echo   with a Firecrawl account API key ^(paid cloud service^):
echo     https://www.firecrawl.dev
echo   Answer N to install only the free local tools ^(default^).
set "USE_FC="
set /p USE_FC="  Add a Firecrawl account now? [y/N]: "
set "FC_API_KEY="
set "FC_API_URL="
if /i not "!USE_FC!"=="y" goto fc_done
set "FC_TRIES=0"
:ask_fckey
set "FC_API_KEY="
set /p FC_API_KEY="    Firecrawl API key (from https://www.firecrawl.dev): "
if not "!FC_API_KEY!"=="" goto fckey_ok
set /a FC_TRIES+=1
if !FC_TRIES! geq 3 (
  echo     [WARNING] No API key entered - continuing WITHOUT a Firecrawl account.
  goto fc_done
)
echo     [WARNING] The API key cannot be empty - try again.
goto ask_fckey
:fckey_ok
set "FC_API_URL="
set /p FC_API_URL="    Firecrawl API URL [press Enter for https://api.firecrawl.dev]: "
if "!FC_API_URL!"=="" set "FC_API_URL=https://api.firecrawl.dev"
:fc_done
echo.

:setup_done
echo.
echo ============================================================
echo   Summary
echo   Folder:         !TARGET!
echo   SearXNG port:   !SEARXNG_PORT!
echo   Firecrawl port: !FIRECRAWL_PORT!
echo   Browser engine: !BROWSER_ENGINE!
echo   Agent skill:    %USERPROFILE%\.agents\skills\local-web-search
if defined OPENAI_BASE_URL (
  echo   LLM endpoint:   !OPENAI_BASE_URL!  !MODEL_NAME!
) else (
  echo   LLM endpoint:   ^(none - enable later by editing .env^)
)
if defined FC_API_KEY (
  echo   Firecrawl acct: !FC_API_URL!  ^(account tools installed^)
) else (
  echo   Firecrawl acct: ^(none - free local tools only^)
)
echo ============================================================
set "CONFIRM="
set /p CONFIRM="Proceed with install? [Y/n]: "
if /i "!CONFIRM!"=="n" ( echo Install cancelled. & pause & exit /b 0 )
REM  All prompts are answered - safe to switch to UTF-8 for the output phase.
chcp 65001 >nul

if not exist "!TARGET!" mkdir "!TARGET!"
if not exist "!TARGET!\config\searxng" mkdir "!TARGET!\config\searxng"
if not exist "!TARGET!\local-web-search\scripts" mkdir "!TARGET!\local-web-search\scripts"

if exist "!TARGET!\.env" (
  for /f "usebackq delims=" %%t in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMddHHmmss"`) do set "LDT=%%t"
  copy /Y "!TARGET!\.env" "!TARGET!\.env.bak.!LDT!" >nul
  echo   Backed up existing .env to .env.bak.!LDT!
)

echo Copying files...

REM --- config/searxng/settings.yml ---
set "NEED_B64=1"
if exist "!SRC!\config\searxng\settings.yml" (
  copy /Y "!SRC!\config\searxng\settings.yml" "!TARGET!\config\searxng\settings.yml" >nul 2>&1
  if exist "!TARGET!\config\searxng\settings.yml" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] config/searxng/settings.yml  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3594602951.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBTZWFyWE5HIHNldHRpbmdzIGZvciBsb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2gKIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PQojICBQcmUtY29uZmlndXJlZCBmb3IgQUkgLyBsb2Nh
  >> "!B64TMP!" echo bC1tb2RlbCB1c2U6CiMgICAgKiBzZWFyY2guZm9ybWF0cyBpbmNsdWRlcyAianNvbiIgIC0+IGxl
  >> "!B64TMP!" echo dHMgbW9kZWxzIHF1ZXJ5IHRoZSBKU09OIEFQSQojICAgICogc2VydmVyLmxpbWl0ZXI6IGZhbHNl
  >> "!B64TMP!" echo ICAgICAgICAgICAtPiBubyByYXRlLWxpbWl0aW5nIG9uIEFQSSBjYWxscwojICAgICogc2VydmVy
  >> "!B64TMP!" echo LnB1YmxpY19pbnN0YW5jZTogZmFsc2UgICAtPiBwcml2YXRlIGluc3RhbmNlIGRlZmF1bHRzCiMg
  >> "!B64TMP!" echo ICAgKiBzZWNyZXRfa2V5IHBsYWNlaG9sZGVyICAgICAgICAgIC0+IGluc3RhbGxlciByZXBsYWNl
  >> "!B64TMP!" echo cyB3aXRoIGEgcmFuZG9tIGtleQojCiMgICJ1c2VfZGVmYXVsdF9zZXR0aW5nczogdHJ1ZSIgaW5o
  >> "!B64TMP!" echo ZXJpdHMgYWxsIHVwc3RyZWFtIGRlZmF1bHRzIChlbmdpbmVzLAojICBwbHVnaW5zLCBldGMuKSBz
  >> "!B64TMP!" echo byBvbmx5IHRoZSBvdmVycmlkZXMgYmVsb3cgdGFrZSBlZmZlY3QuCiMgPT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT0KCnVzZV9kZWZhdWx0X3NldHRpbmdzOiB0cnVlCgpnZW5lcmFsOgogIGRlYnVnOiBmYWxz
  >> "!B64TMP!" echo ZQogIGluc3RhbmNlX25hbWU6ICJMb2NhbCBTZWFyY2giCiAgcHJpdmFjeXBvbGljeV91cmw6IGZh
  >> "!B64TMP!" echo bHNlCiAgY29udGFjdF9saW5rOiBmYWxzZQoKc2VhcmNoOgogIHNhZmVfc2VhcmNoOiAwCiAgYXV0
  >> "!B64TMP!" echo b2NvbXBsZXRlOiAiIgogIGRlZmF1bHRfbGFuZzogImVuIgogIGZvcm1hdHM6CiAgICAtIGh0bWwK
  >> "!B64TMP!" echo ICAgIC0ganNvbgoKc2VydmVyOgogIHNlY3JldF9rZXk6ICIzMjY0NWZiMzBjNmQ0Y2JlMjE3YzY3
  >> "!B64TMP!" echo OTU2ZDNkYjAwZDM3N2I0ZmRlZDE4NDU1NDk3YjA3M2IzYjBkYzQyNTNjIgogIGJpbmRfYWRkcmVz
  >> "!B64TMP!" echo czogIjAuMC4wLjAiCiAgcG9ydDogODA4MAogIGltYWdlX3Byb3h5OiB0cnVlCiAgbGltaXRlcjog
  >> "!B64TMP!" echo ZmFsc2UKICBwdWJsaWNfaW5zdGFuY2U6IGZhbHNlCgp1aToKICBzdGF0aWNfdXNlX2hhc2g6IHRy
  >> "!B64TMP!" echo dWUKCm91dGdvaW5nOgogIHJlcXVlc3RfdGltZW91dDogMTAuMAogIG1heF9yZXF1ZXN0X3RpbWVv
  >> "!B64TMP!" echo dXQ6IDE1LjAK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\config\searxng\settings.yml"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- docker-compose.yml ---
set "NEED_B64=1"
if exist "!SRC!\docker-compose.yml" (
  copy /Y "!SRC!\docker-compose.yml" "!TARGET!\docker-compose.yml" >nul 2>&1
  if exist "!TARGET!\docker-compose.yml" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] docker-compose.yml  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS548588679.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBMb2NhbCBTZWFyY2gg4oCUIEZpcmVjcmF3bCArIFNl
  >> "!B64TMP!" echo YXJYTkcgKGxvY2FsIHdlYi1icm93c2luZyBzeXN0ZW0gZm9yIEFJIG1vZGVscykKIyA9PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PQojICBUaGlzIENvbXBvc2UgZmlsZSBpcyBjb25zdW1lZCBieSB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbGVycyAoaW5zdGFsbC1sb2NhbC1zZWFyY2guYmF0IC8KIyAgaW5zdGFsbC1sb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2guc2gpLiBUaGUgaG9zdCBwb3J0cyBhbmQgY3JlZGVudGlhbHMgYXJlIGluamVjdGVkIGZyb20K
  >> "!B64TMP!" echo IyAgdGhlIGdlbmVyYXRlZCAuZW52IGZpbGUgKGNyZWF0ZWQgYXQgaW5zdGFsbCB0aW1lKS4KIwoj
  >> "!B64TMP!" echo ICBTZXJ2aWNlczoKIyAgICBzZWFyeG5nICAgICAgICAgICAgIG1ldGFzZWFyY2ggKyBKU09OIEFQ
  >> "!B64TMP!" echo SSAgICAgICAgLT4gaG9zdCAke1NFQVJYTkdfUE9SVH0KIyAgICBmaXJlY3Jhd2wgICAgICAgICAg
  >> "!B64TMP!" echo IHNjcmFwZS9jcmF3bC9zZWFyY2gvbWFwIEFQSSAgLT4gaG9zdCAke0ZJUkVDUkFXTF9QT1JUfQoj
  >> "!B64TMP!" echo ICAgIHBsYXl3cmlnaHQtc2VydmljZSAgSlMgcmVuZGVyaW5nIGZvciBGaXJlY3Jhd2wgKHByb2Zp
  >> "!B64TMP!" echo bGU6IHBsYXl3cmlnaHQpCiMgICAgYnJvd3Nlcmxlc3MgICAgICAgICBzdGVhbHRoIEpTIHJlbmRl
  >> "!B64TMP!" echo cmluZyBmb3IgRmlyZWNyYXdsIChwcm9maWxlOiBicm93c2VybGVzcykKIyAgICByZWRpcyAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgIHF1ZXVlIGZvciBGaXJlY3Jhd2wKIyAgICByYWJiaXRtcSAgICAgICAgICAgIG1l
  >> "!B64TMP!" echo c3NhZ2UgYnJva2VyIGZvciBGaXJlY3Jhd2wKIyAgICBudXEtcG9zdGdyZXMgICAgICAgIGpvYiBz
  >> "!B64TMP!" echo dGF0ZSBEQiBmb3IgRmlyZWNyYXdsCiMKIyAgT25seSBPTkUgb2YgcGxheXdyaWdodC1zZXJ2aWNl
  >> "!B64TMP!" echo IC8gYnJvd3Nlcmxlc3MgYWN0dWFsbHkgc3RhcnRzOiB0aGUKIyAgaW5zdGFsbGVyJ3MgIkJyb3dz
  >> "!B64TMP!" echo ZXIgcmVuZGVyaW5nIGVuZ2luZSIgcXVlc3Rpb24gd3JpdGVzIENPTVBPU0VfUFJPRklMRVMKIyAg
  >> "!B64TMP!" echo dG8gLmVudiAoZGVmYXVsdCAicGxheXdyaWdodCIpIHRvIHBpY2sgd2hpY2ggb25lLCBhbmQgcG9p
  >> "!B64TMP!" echo bnRzCiMgIFBMQVlXUklHSFRfTUlDUk9TRVJWSUNFX1VSTCBhdCBpdC4gVGhlIG90aGVyIHN0YXlz
  >> "!B64TMP!" echo IGRlZmluZWQgYnV0IGRvcm1hbnQuCiMKIyAgT25seSB0aGUgdHdvIGhvc3QgcG9ydHMgYmVsb3cg
  >> "!B64TMP!" echo YXJlIHB1Ymxpc2hlZC4gRXZlcnl0aGluZyBlbHNlIHN0YXlzIG9uIHRoZQojICBwcml2YXRlICJs
  >> "!B64TMP!" echo b2NhbC1zZWFyY2gtbmV0IiBicmlkZ2UgbmV0d29yay4KIwojICBXb3JrcyB3aXRoIERvY2tlciBB
  >> "!B64TMP!" echo TkQgUG9kbWFuICh0aGUgTGludXgvbWFjT1MgaW5zdGFsbGVyIHByZWZlcnMgUG9kbWFuIHdoZW4K
  >> "!B64TMP!" echo IyAgYm90aCBhcmUgaW5zdGFsbGVkKS4gVHdvIHRoaW5ncyBtYWtlIHRoYXQgc2FmZToKIyAgICAq
  >> "!B64TMP!" echo IEV2ZXJ5IGltYWdlIGlzIGZ1bGx5IHF1YWxpZmllZCAoZG9ja2VyLmlvLy4uLiwgZ2hjci5pby8u
  >> "!B64TMP!" echo Li4pLCBzbyBQb2RtYW4KIyAgICAgIG5ldmVyIGhhcyB0byBndWVzcyBhIHJlZ2lzdHJ5IG9yIGFz
  >> "!B64TMP!" echo ayAid2hpY2ggb25lPyIgZm9yIGEgc2hvcnQgbmFtZSAtCiMgICAgICBpbWFnZXMgb25seSBldmVy
  >> "!B64TMP!" echo IGNvbWUgZnJvbSBEb2NrZXIgSHViIGFuZCBHSENSLgojICAgICogU2VhclhORydzIGJpbmQtbW91
  >> "!B64TMP!" echo bnRlZCBjb25maWcgZm9sZGVyIGlzIHR1bmVkIGZyb20gLmVudiAod3JpdHRlbiBieQojICAgICAg
  >> "!B64TMP!" echo aW5zdGFsbC1sb2NhbC1zZWFyY2guc2gpIC0gc2VlIHRoZSBTRUFSWE5HX01PVU5UX09QVFMgLwoj
  >> "!B64TMP!" echo ICAgICAgU0VBUlhOR19GT1JDRV9PV05FUlNISVAgbm90ZXMgb24gdGhlIHNlYXJ4bmcgc2Vydmlj
  >> "!B64TMP!" echo ZS4KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PQoKbmFtZTogbG9jYWwtc2VhcmNoCgpzZXJ2aWNlczoK
  >> "!B64TMP!" echo CiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMgU2VhclhORyDigJQgcHJpdmFjeS1yZXNwZWN0aW5n
  >> "!B64TMP!" echo IG1ldGFzZWFyY2ggZW5naW5lLCBleHBvc2VkIGFzIGEgSlNPTiBBUEkuCiAgIyBQb3dlcnMgYm90
  >> "!B64TMP!" echo aCB5b3VyIEFJIG1vZGVscyAoZGlyZWN0IEpTT04gcXVlcmllcykgYW5kIEZpcmVjcmF3bCdzIC92
  >> "!B64TMP!" echo MS9zZWFyY2guCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIHNlYXJ4bmc6CiAgICBpbWFnZTogZG9j
  >> "!B64TMP!" echo a2VyLmlvL3NlYXJ4bmcvc2VhcnhuZzpsYXRlc3QKICAgIGNvbnRhaW5lcl9uYW1lOiBsb2NhbC1z
  >> "!B64TMP!" echo ZWFyY2gtc2VhcnhuZwogICAgcG9ydHM6CiAgICAgIC0gIiR7U0VBUlhOR19QT1JUOi05OTkwfTo4
  >> "!B64TMP!" echo MDgwIgogICAgIyBTRUFSWE5HX01PVU5UX09QVFMgKGZyb20gLmVudikgYXBwZW5kcyBleHRyYSBi
  >> "!B64TMP!" echo aW5kLW1vdW50IG9wdGlvbnMuIE9uIGhvc3RzCiAgICAjIHdpdGggU0VMaW51eCAoRmVkb3JhLCBS
  >> "!B64TMP!" echo SEVMLCAuLi4pIHRoZSBpbnN0YWxsZXIgc2V0cyBpdCB0byAiLHoiIHNvIHRoZQogICAgIyBjb250
  >> "!B64TMP!" echo YWluZXIgbWF5IHJlYWQgL2V0Yy9zZWFyeG5nOyB3aXRob3V0IHRoYXQgbGFiZWwgU2VhclhORyBk
  >> "!B64TMP!" echo aWVzIGF0CiAgICAjIHN0YXJ0LXVwIHdpdGggImNob3duL2NwL3NlZDogLi4uIFBlcm1pc3Npb24g
  >> "!B64TMP!" echo ZGVuaWVkIiBhbmQgcmVzdGFydC1sb29wcy4KICAgICMgSXQgaXMgZW1wdHkgZXZlcnl3aGVyZSBl
  >> "!B64TMP!" echo bHNlIChXaW5kb3dzLCBtYWNPUywgVWJ1bnR1LCAuLi4pLgogICAgdm9sdW1lczoKICAgICAgLSAu
  >> "!B64TMP!" echo L2NvbmZpZy9zZWFyeG5nOi9ldGMvc2VhcnhuZzpydyR7U0VBUlhOR19NT1VOVF9PUFRTOi19CiAg
  >> "!B64TMP!" echo ICBlbnZpcm9ubWVudDoKICAgICAgLSBTRUFSWE5HX0JBU0VfVVJMPWh0dHA6Ly9sb2NhbGhvc3Q6
  >> "!B64TMP!" echo JHtTRUFSWE5HX1BPUlQ6LTk5OTB9LwogICAgICAtIFVXU0dJX1dPUktFUlM9NAogICAgICAtIFVX
  >> "!B64TMP!" echo U0dJX1RIUkVBRFM9NAogICAgICAtIFNFQVJYTkdfU0VDUkVUPSR7U0VBUlhOR19TRUNSRVR9CiAg
  >> "!B64TMP!" echo ICAgICMgVGhlIGltYWdlJ3MgZW50cnlwb2ludCBjaG93bnMgdGhlIG1vdW50ZWQgY29uZmlnIGZv
  >> "!B64TMP!" echo bGRlciB0byBpdHMgb3duCiAgICAgICMgInNlYXJ4bmciIHVzZXIgdW5sZXNzIHRoaXMgaXMgImZh
  >> "!B64TMP!" echo bHNlIi4gUm9vdGxlc3MgUG9kbWFuIHdvdWxkIHR1cm4gdGhlCiAgICAgICMgaG9zdCBmaWxlcyBp
  >> "!B64TMP!" echo bnRvIGEgc3ViLVVJRCB5b3UgY2Fubm90IGVkaXQgb3IgZGVsZXRlLCBzbyB0aGUgaW5zdGFsbGVy
  >> "!B64TMP!" echo CiAgICAgICMgc2V0cyAiZmFsc2UiIHRoZXJlOyBpdCBzdGF5cyAidHJ1ZSIgKHRoZSBpbWFnZSBk
  >> "!B64TMP!" echo ZWZhdWx0KSBvdGhlcndpc2UuCiAgICAgIC0gRk9SQ0VfT1dORVJTSElQPSR7U0VBUlhOR19GT1JD
  >> "!B64TMP!" echo RV9PV05FUlNISVA6LXRydWV9CiAgICByZXN0YXJ0OiB1bmxlc3Mtc3RvcHBlZAogICAgY2FwX2Ry
  >> "!B64TMP!" echo b3A6CiAgICAgIC0gQUxMCiAgICBjYXBfYWRkOgogICAgICAtIENIT1dOCiAgICAgIC0gU0VUR0lE
  >> "!B64TMP!" echo CiAgICAgIC0gU0VUVUlECiAgICBuZXR3b3JrczoKICAgICAgLSBsb2NhbC1zZWFyY2gtbmV0Cgog
  >> "!B64TMP!" echo ICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0KICAjIEZpcmVjcmF3bCBBUEkgc2VydmVyICh0aGUgcHVibGlj
  >> "!B64TMP!" echo LWZhY2luZyBzY3JhcGluZy9jcmF3bC9zZWFyY2ggc2VydmljZSkuCiAgIyAtLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLQogIGZpcmVjcmF3bDoKICAgIGltYWdlOiBnaGNyLmlvL2ZpcmVjcmF3bC9maXJlY3Jhd2w6
  >> "!B64TMP!" echo bGF0ZXN0CiAgICBjb250YWluZXJfbmFtZTogbG9jYWwtc2VhcmNoLWZpcmVjcmF3bAogICAgcG9y
  >> "!B64TMP!" echo dHM6CiAgICAgIC0gIiR7RklSRUNSQVdMX1BPUlQ6LTk5OTF9OjMwMDIiCiAgICBlbnZpcm9ubWVu
  >> "!B64TMP!" echo dDoKICAgICAgLSBQT1JUPTMwMDIKICAgICAgLSBIT1NUPTAuMC4wLjAKICAgICAgLSBFTlY9bG9j
  >> "!B64TMP!" echo YWwKICAgICAgLSBSRURJU19VUkw9cmVkaXM6Ly9yZWRpczo2Mzc5CiAgICAgIC0gUkVESVNfUkFU
  >> "!B64TMP!" echo RV9MSU1JVF9VUkw9cmVkaXM6Ly9yZWRpczo2Mzc5CiAgICAgIC0gUExBWVdSSUdIVF9NSUNST1NF
  >> "!B64TMP!" echo UlZJQ0VfVVJMPSR7UExBWVdSSUdIVF9NSUNST1NFUlZJQ0VfVVJMOi1odHRwOi8vcGxheXdyaWdo
  >> "!B64TMP!" echo dC1zZXJ2aWNlOjMwMDAvc2NyYXBlfQogICAgICAtIFVTRV9EQl9BVVRIRU5USUNBVElPTj1mYWxz
  >> "!B64TMP!" echo ZQogICAgICAtIEJVTExfQVVUSF9LRVk9JHtCVUxMX0FVVEhfS0VZfQogICAgICAtIExPR0dJTkdf
  >> "!B64TMP!" echo TEVWRUw9JHtMT0dHSU5HX0xFVkVMOi1pbmZvfQogICAgICAtIEJMT0NLX01FRElBPWZhbHNlCiAg
  >> "!B64TMP!" echo ICAgICMgRmlyZWNyYXdsJ3MgU1NSRiBndWFyZCByZWZ1c2VzIHByaXZhdGUvcmVzZXJ2ZWQgYWRk
  >> "!B64TMP!" echo cmVzc2VzLCBidXQgcHJveHkgYW5kIFZQTiB0b29scyAoQ2xhc2gKICAgICAgIyBmYWtlLUlQLCBX
  >> "!B64TMP!" echo QVJQLCAuLi4pIGhhbmQgdGhvc2Ugb3V0IGZvciBwdWJsaWMgc2l0ZXMsIHNvIGV2ZXJ5IHNjcmFw
  >> "!B64TMP!" echo ZSB3b3VsZCBmYWlsLiBUaGlzIHN0YWNrCiAgICAgICMgaXMgbG9jYWxob3N0LW9ubHk6IHRoZSBn
  >> "!B64TMP!" echo dWFyZCBpcyBvZmYgaGVyZSBhbmQgaW4gcGxheXdyaWdodC1zZXJ2aWNlLgogICAgICAtIEFMTE9X
  >> "!B64TMP!" echo X0xPQ0FMX1dFQkhPT0tTPXRydWUKICAgICAgLSBTRUFSWE5HX0VORFBPSU5UPWh0dHA6Ly9zZWFy
  >> "!B64TMP!" echo eG5nOjgwODAKICAgICAgLSBQT1NUR1JFU19IT1NUPW51cS1wb3N0Z3JlcwogICAgICAtIFBPU1RH
  >> "!B64TMP!" echo UkVTX1BPUlQ9NTQzMgogICAgICAtIFBPU1RHUkVTX0RCPSR7UE9TVEdSRVNfREI6LWZpcmVjcmF3
  >> "!B64TMP!" echo bH0KICAgICAgLSBQT1NUR1JFU19VU0VSPSR7UE9TVEdSRVNfVVNFUjotZmlyZWNyYXdsfQogICAg
  >> "!B64TMP!" echo ICAtIFBPU1RHUkVTX1BBU1NXT1JEPSR7UE9TVEdSRVNfUEFTU1dPUkR9CiAgICAgIC0gTlVRX1JB
  >> "!B64TMP!" echo QkJJVE1RX1VSTD1hbXFwOi8vJHtSQUJCSVRNUV9VU0VSOi1maXJlY3Jhd2x9OiR7UkFCQklUTVFf
  >> "!B64TMP!" echo UEFTU1dPUkR9QHJhYmJpdG1xOjU2NzIKICAgICAgIyAtLS0tIE9wdGlvbmFsIEFJIGZlYXR1cmVz
  >> "!B64TMP!" echo IChzZXQgaW4gLmVudiB0byBlbmFibGUgL3YxL2V4dHJhY3QgKyBzdW1tYXJ5KSAtLS0tCiAgICAg
  >> "!B64TMP!" echo IC0gT1BFTkFJX0FQSV9LRVk9JHtPUEVOQUlfQVBJX0tFWTotfQogICAgICAtIE9QRU5BSV9CQVNF
  >> "!B64TMP!" echo X1VSTD0ke09QRU5BSV9CQVNFX1VSTDotfQogICAgICAtIE9MTEFNQV9CQVNFX1VSTD0ke09MTEFN
  >> "!B64TMP!" echo QV9CQVNFX1VSTDotfQogICAgICAtIE1PREVMX05BTUU9JHtNT0RFTF9OQU1FOi19CiAgICAgIC0g
  >> "!B64TMP!" echo TU9ERUxfRU1CRURESU5HX05BTUU9JHtNT0RFTF9FTUJFRERJTkdfTkFNRTotfQogICAgY29tbWFu
  >> "!B64TMP!" echo ZDogWyJub2RlIiwgImRpc3Qvc3JjL2hhcm5lc3MuanMiLCAiLS1zdGFydC1kb2NrZXIiXQogICAg
  >> "!B64TMP!" echo dWxpbWl0czoKICAgICAgbm9maWxlOgogICAgICAgIHNvZnQ6IDY1NTM1CiAgICAgICAgaGFyZDog
  >> "!B64TMP!" echo NjU1MzUKICAgIGV4dHJhX2hvc3RzOgogICAgICAtICJob3N0LmRvY2tlci5pbnRlcm5hbDpob3N0
  >> "!B64TMP!" echo LWdhdGV3YXkiCiAgICBsb2dnaW5nOgogICAgICBkcml2ZXI6ICJqc29uLWZpbGUiCiAgICAgIG9w
  >> "!B64TMP!" echo dGlvbnM6CiAgICAgICAgbWF4LXNpemU6ICIxMG0iCiAgICAgICAgbWF4LWZpbGU6ICIzIgogICAg
  >> "!B64TMP!" echo ICAgIGNvbXByZXNzOiAidHJ1ZSIKICAgICMgTk9URTogcGxheXdyaWdodC1zZXJ2aWNlIC8gYnJv
  >> "!B64TMP!" echo d3Nlcmxlc3MgYXJlIGRlbGliZXJhdGVseSBOT1QgbGlzdGVkIGhlcmUuCiAgICAjIFRoZXkgYXJl
  >> "!B64TMP!" echo IHByb2ZpbGUtZ2F0ZWQgKG9ubHkgb25lIG9mIHRoZW0gcnVucyksIGFuZCBwb2RtYW4tY29tcG9z
  >> "!B64TMP!" echo ZSBjcmFzaGVzCiAgICAjIHdpdGggIktleUVycm9yOiAnYnJvd3Nlcmxlc3MnIiB3aGVuIGEgc2Vy
  >> "!B64TMP!" echo dmljZSBkZXBlbmRzIG9uIG9uZSB0aGF0IGl0cwogICAgIyBwcm9maWxlIGRpc2FibGVkLiBEb2Nr
  >> "!B64TMP!" echo ZXIgb25seSBldmVyIGhvbm91cmVkIHRoYXQgZGVwZW5kZW5jeSBhcyBzdGFydAogICAgIyBPUkRF
  >> "!B64TMP!" echo UiAoc2VydmljZV9zdGFydGVkICsgcmVxdWlyZWQ6IGZhbHNlLCBuZXZlciByZWFkaW5lc3MpLCBh
  >> "!B64TMP!" echo bmQgRmlyZWNyYXdsCiAgICAjIHJlYWNoZXMgdGhlIGJyb3dzZXIgc2VydmljZSBwZXIgc2NyYXBl
  >> "!B64TMP!" echo IHJlcXVlc3QsIG5vdCBhdCBzdGFydC11cCwgc28KICAgICMgbm90aGluZyBpcyBsb3N0LiBLZWVw
  >> "!B64TMP!" echo IHByb2ZpbGUtZ2F0ZWQgc2VydmljZXMgb3V0IG9mIGV2ZXJ5IGRlcGVuZHNfb24uCiAgICBkZXBl
  >> "!B64TMP!" echo bmRzX29uOgogICAgICByZWRpczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2Vfc3RhcnRlZAog
  >> "!B64TMP!" echo ICAgICBzZWFyeG5nOgogICAgICAgIGNvbmRpdGlvbjogc2VydmljZV9zdGFydGVkCiAgICAgIG51
  >> "!B64TMP!" echo cS1wb3N0Z3JlczoKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgICByYWJi
  >> "!B64TMP!" echo aXRtcToKICAgICAgICBjb25kaXRpb246IHNlcnZpY2VfaGVhbHRoeQogICAgcmVzdGFydDogdW5s
  >> "!B64TMP!" echo ZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQKCiAgIyAt
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLQogICMgUGxheXdyaWdodCBoZWFkbGVzcyBicm93c2VyIHNlcnZpY2Ug
  >> "!B64TMP!" echo 4oCUIGRvZXMgdGhlIGFjdHVhbCBKUy1yZW5kZXJlZAogICMgZmV0Y2hpbmcuIE9ubHkgc3RhcnRz
  >> "!B64TMP!" echo IHdoZW4gQ09NUE9TRV9QUk9GSUxFUz1wbGF5d3JpZ2h0ICh0aGUgaW5zdGFsbGVyJ3MKICAjIGRl
  >> "!B64TMP!" echo ZmF1bHQgYW5zd2VyIHRvICJCcm93c2VyIHJlbmRlcmluZyBlbmdpbmUiKS4KICAjIC0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tCiAgcGxheXdyaWdodC1zZXJ2aWNlOgogICAgaW1hZ2U6IGdoY3IuaW8vZmlyZWNy
  >> "!B64TMP!" echo YXdsL3BsYXl3cmlnaHQtc2VydmljZTpsYXRlc3QKICAgIGNvbnRhaW5lcl9uYW1lOiBsb2NhbC1z
  >> "!B64TMP!" echo ZWFyY2gtcGxheXdyaWdodAogICAgcHJvZmlsZXM6IFsicGxheXdyaWdodCJdCiAgICBlbnZpcm9u
  >> "!B64TMP!" echo bWVudDoKICAgICAgLSBQT1JUPTMwMDAKICAgICAgLSBCTE9DS19NRURJQT1mYWxzZQogICAgICAt
  >> "!B64TMP!" echo IEFMTE9XX0xPQ0FMX1dFQkhPT0tTPXRydWUKICAgICAgLSBNQVhfQ09OQ1VSUkVOVF9QQUdFUz0x
  >> "!B64TMP!" echo MAogICAgcmVzdGFydDogdW5sZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaC1uZXQKCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMgQnJvd3Nlcmxlc3MgKGNvbW11
  >> "!B64TMP!" echo bml0eSBlZGl0aW9uKSDigJQgc3RlYWx0aCBoZWFkbGVzcyBDaHJvbWl1bSB0aGF0IGRvZXMgdGhl
  >> "!B64TMP!" echo CiAgIyBhY3R1YWwgSlMtcmVuZGVyZWQgZmV0Y2hpbmcgZm9yIEZpcmVjcmF3bC4gREVGQVVMVF9T
  >> "!B64TMP!" echo VEVBTFRIPXRydWUgYXBwbGllcwogICMgdGhlIGJ1aWx0LWluIHN0ZWFsdGggcGF0Y2hlcyAobWFz
  >> "!B64TMP!" echo a3MgYXV0b21hdGlvbiBmaW5nZXJwcmludHMgc3VjaCBhcwogICMgbmF2aWdhdG9yLndlYmRyaXZl
  >> "!B64TMP!" echo cikgdG8gZXZlcnkgcmVxdWVzdCB3aXRob3V0IG5lZWRpbmcgYSA/c3RlYWx0aCBxdWVyeQogICMg
  >> "!B64TMP!" echo cGFyYW0sIHdoaWNoIGhlbHBzIHBhZ2VzIGZyb250ZWQgYnkgQ2xvdWRmbGFyZSBhbmQgc2ltaWxh
  >> "!B64TMP!" echo ciBib3QgY2hlY2tzLgogICMgT25seSBzdGFydHMgd2hlbiBDT01QT1NFX1BST0ZJTEVTPWJyb3dz
  >> "!B64TMP!" echo ZXJsZXNzICh0aGUgaW5zdGFsbGVyJ3MgIlVzZQogICMgQnJvd3Nlcmxlc3MgaW5zdGVhZD8iIGFu
  >> "!B64TMP!" echo c3dlcikuCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIGJyb3dzZXJsZXNzOgogICAgaW1hZ2U6IGdo
  >> "!B64TMP!" echo Y3IuaW8vYnJvd3Nlcmxlc3MvY2hyb21pdW06bGF0ZXN0CiAgICBjb250YWluZXJfbmFtZTogbG9j
  >> "!B64TMP!" echo YWwtc2VhcmNoLWJyb3dzZXJsZXNzCiAgICBwcm9maWxlczogWyJicm93c2VybGVzcyJdCiAgICBl
  >> "!B64TMP!" echo bnZpcm9ubWVudDoKICAgICAgLSBQT1JUPTMwMDAKICAgICAgLSBUT0tFTj0ke0JST1dTRVJMRVNT
  >> "!B64TMP!" echo X1RPS0VOOi19CiAgICAgIC0gREVGQVVMVF9TVEVBTFRIPXRydWUKICAgICAgLSBDT05DVVJSRU5U
  >> "!B64TMP!" echo PTEwCiAgICAgIC0gTUFYX0NPTkNVUlJFTlRfU0VTU0lPTlM9MTAKICAgIHJlc3RhcnQ6IHVubGVz
  >> "!B64TMP!" echo cy1zdG9wcGVkCiAgICBuZXR3b3JrczoKICAgICAgLSBsb2NhbC1zZWFyY2gtbmV0CgogICMgLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0KICAjIFJlZGlzIOKAlCBGaXJlY3Jhd2wgcXVldWUgLyByYXRlLWxpbWl0
  >> "!B64TMP!" echo aW5nIHN0b3JlLgogICMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICByZWRpczoKICAgIGltYWdlOiBkb2Nr
  >> "!B64TMP!" echo ZXIuaW8vbGlicmFyeS9yZWRpczphbHBpbmUKICAgIGNvbnRhaW5lcl9uYW1lOiBsb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2gtcmVkaXMKICAgIHZvbHVtZXM6CiAgICAgIC0gcmVkaXMtZGF0YTovZGF0YQogICAgcmVzdGFy
  >> "!B64TMP!" echo dDogdW5sZXNzLXN0b3BwZWQKICAgIG5ldHdvcmtzOgogICAgICAtIGxvY2FsLXNlYXJjaC1uZXQK
  >> "!B64TMP!" echo CiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogICMgUmFiYml0TVEg4oCUIG1lc3NhZ2UgYnJva2VyIHVz
  >> "!B64TMP!" echo ZWQgYnkgRmlyZWNyYXdsJ3Mgam9iIHdvcmtlcnMuCiAgIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogIHJh
  >> "!B64TMP!" echo YmJpdG1xOgogICAgaW1hZ2U6IGRvY2tlci5pby9saWJyYXJ5L3JhYmJpdG1xOjMtbWFuYWdlbWVu
  >> "!B64TMP!" echo dAogICAgY29udGFpbmVyX25hbWU6IGxvY2FsLXNlYXJjaC1yYWJiaXRtcQogICAgZW52aXJvbm1l
  >> "!B64TMP!" echo bnQ6CiAgICAgIC0gUkFCQklUTVFfREVGQVVMVF9VU0VSPSR7UkFCQklUTVFfVVNFUjotZmlyZWNy
  >> "!B64TMP!" echo YXdsfQogICAgICAtIFJBQkJJVE1RX0RFRkFVTFRfUEFTUz0ke1JBQkJJVE1RX1BBU1NXT1JEfQog
  >> "!B64TMP!" echo ICAgdm9sdW1lczoKICAgICAgLSByYWJiaXRtcS1kYXRhOi92YXIvbGliL3JhYmJpdG1xCiAgICBo
  >> "!B64TMP!" echo ZWFsdGhjaGVjazoKICAgICAgdGVzdDogWyJDTUQiLCAicmFiYml0bXEtZGlhZ25vc3RpY3MiLCAi
  >> "!B64TMP!" echo cGluZyJdCiAgICAgIGludGVydmFsOiA1cwogICAgICB0aW1lb3V0OiAxMHMKICAgICAgcmV0cmll
  >> "!B64TMP!" echo czogMTAKICAgICAgc3RhcnRfcGVyaW9kOiAzMHMKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVk
  >> "!B64TMP!" echo CiAgICBuZXR3b3JrczoKICAgICAgLSBsb2NhbC1zZWFyY2gtbmV0CgogICMgLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0KICAjIG51cS1wb3N0Z3JlcyDigJQgRmlyZWNyYXdsIGpvYi1zdGF0ZSBkYXRhYmFzZSAo
  >> "!B64TMP!" echo cGdfY3JvbiBlbmFibGVkIGltYWdlKS4KICAjIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgbnVxLXBvc3Rn
  >> "!B64TMP!" echo cmVzOgogICAgaW1hZ2U6IGdoY3IuaW8vZmlyZWNyYXdsL251cS1wb3N0Z3JlczpsYXRlc3QKICAg
  >> "!B64TMP!" echo IGNvbnRhaW5lcl9uYW1lOiBsb2NhbC1zZWFyY2gtcG9zdGdyZXMKICAgIGNvbW1hbmQ6IHBvc3Rn
  >> "!B64TMP!" echo cmVzIC1jIGNyb24uZGF0YWJhc2VfbmFtZT0ke1BPU1RHUkVTX0RCOi1maXJlY3Jhd2x9CiAgICBl
  >> "!B64TMP!" echo bnZpcm9ubWVudDoKICAgICAgLSBQT1NUR1JFU19EQj0ke1BPU1RHUkVTX0RCOi1maXJlY3Jhd2x9
  >> "!B64TMP!" echo CiAgICAgIC0gUE9TVEdSRVNfVVNFUj0ke1BPU1RHUkVTX1VTRVI6LWZpcmVjcmF3bH0KICAgICAg
  >> "!B64TMP!" echo LSBQT1NUR1JFU19QQVNTV09SRD0ke1BPU1RHUkVTX1BBU1NXT1JEfQogICAgdm9sdW1lczoKICAg
  >> "!B64TMP!" echo ICAgLSBwb3N0Z3Jlcy1kYXRhOi92YXIvbGliL3Bvc3RncmVzcWwvZGF0YQogICAgaGVhbHRoY2hl
  >> "!B64TMP!" echo Y2s6CiAgICAgIHRlc3Q6IFsiQ01ELVNIRUxMIiwgInBnX2lzcmVhZHkgLVUgJHtQT1NUR1JFU19V
  >> "!B64TMP!" echo U0VSOi1maXJlY3Jhd2x9IC1kICR7UE9TVEdSRVNfREI6LWZpcmVjcmF3bH0iXQogICAgICBpbnRl
  >> "!B64TMP!" echo cnZhbDogNXMKICAgICAgdGltZW91dDogNXMKICAgICAgcmV0cmllczogMTAKICAgICAgc3RhcnRf
  >> "!B64TMP!" echo cGVyaW9kOiAzMHMKICAgIHJlc3RhcnQ6IHVubGVzcy1zdG9wcGVkCiAgICBuZXR3b3JrczoKICAg
  >> "!B64TMP!" echo ICAgLSBsb2NhbC1zZWFyY2gtbmV0CgpuZXR3b3JrczoKICBsb2NhbC1zZWFyY2gtbmV0OgogICAg
  >> "!B64TMP!" echo ZHJpdmVyOiBicmlkZ2UKCnZvbHVtZXM6CiAgcmVkaXMtZGF0YToKICBwb3N0Z3Jlcy1kYXRhOgog
  >> "!B64TMP!" echo IHJhYmJpdG1xLWRhdGE6Cg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\docker-compose.yml"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- .env.example ---
set "NEED_B64=1"
if exist "!SRC!\.env.example" (
  copy /Y "!SRC!\.env.example" "!TARGET!\.env.example" >nul 2>&1
  if exist "!TARGET!\.env.example" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] .env.example  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS4173156074.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBMb2NhbCBTZWFyY2gg4oCUIGV4YW1wbGUgZW52aXJv
  >> "!B64TMP!" echo bm1lbnQgZmlsZQojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09CiMgIFRoZSBpbnN0YWxsZXIgKGluc3Rh
  >> "!B64TMP!" echo bGwtbG9jYWwtc2VhcmNoLmJhdCAvIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoKSBnZW5lcmF0ZXMK
  >> "!B64TMP!" echo IyAgYSBSRUFMIC5lbnYgZmlsZSBhdCBpbnN0YWxsIHRpbWUgd2l0aDoKIyAgICAqIHRoZSBob3N0
  >> "!B64TMP!" echo IHBvcnRzIHlvdSBjaG9zZQojICAgICogY3J5cHRvZ3JhcGhpY2FsbHktcmFuZG9tIHBhc3N3b3Jk
  >> "!B64TMP!" echo cy9rZXlzIChkbyBOT1QgdXNlIHRoZSB2YWx1ZXMgYmVsb3cKIyAgICAgIGluIHByb2R1Y3Rpb24g
  >> "!B64TMP!" echo 4oCUIHRoZXkgYXJlIHBsYWNlaG9sZGVycyBvbmx5KQojCiMgIFRoaXMgZmlsZSBpcyBkb2N1bWVu
  >> "!B64TMP!" echo dGF0aW9uLiBUbyBjaGFuZ2Ugc2V0dGluZ3MgYWZ0ZXIgaW5zdGFsbCwgZWRpdCB0aGUgLmVudgoj
  >> "!B64TMP!" echo ICBpbiB5b3VyIGluc3RhbGwgZm9sZGVyLCB0aGVuIHJ1biBVcGRhdGUuYmF0IC8gdXBkYXRlLnNo
  >> "!B64TMP!" echo IChvciByZXN0YXJ0KS4KIyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PQoKIyAtLS0tIEhvc3QgcG9ydHMg
  >> "!B64TMP!" echo KHdoYXQgeW91IGNvbm5lY3QgdG8gZnJvbSB5b3VyIG1hY2hpbmUpIC0tLS0KU0VBUlhOR19QT1JU
  >> "!B64TMP!" echo PTk5OTAKRklSRUNSQVdMX1BPUlQ9OTk5MQoKIyAtLS0tIFNlYXJYTkcgaW5zdGFuY2Ugc2VjcmV0
  >> "!B64TMP!" echo IChyYW5kb20g4oCUIGluc3RhbGxlciBnZW5lcmF0ZXMpIC0tLS0KU0VBUlhOR19TRUNSRVQ9cmVw
  >> "!B64TMP!" echo bGFjZS13aXRoLTY0LWNoYXItcmFuZG9tLWhleAoKIyAtLS0tIENvbnRhaW5lciBlbmdpbmUgKExp
  >> "!B64TMP!" echo bnV4L21hY09TIGluc3RhbGxlcjogaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gpIC0tLS0KIyAgIHBv
  >> "!B64TMP!" echo ZG1hbiBvciBkb2NrZXIuIFRoZSBpbnN0YWxsZXIgcHJlZmVycyBQb2RtYW4gd2hlbiBpdCBpcyBp
  >> "!B64TMP!" echo bnN0YWxsZWQgKGV2ZW4gaWYKIyAgIERvY2tlciBpcyB0b28pIGFuZCByZWNvcmRzIHdoYXQgaXQg
  >> "!B64TMP!" echo dXNlZCBoZXJlLCBzbyBydW4uc2ggLyBzdG9wLnNoIC8gdXBkYXRlLnNoCiMgICBrZWVwIHVzaW5n
  >> "!B64TMP!" echo IHRoZSBzYW1lIGVuZ2luZS4gU2V0IGl0IHlvdXJzZWxmIHRvIHN3aXRjaCwgdGhlbiBydW4gdXBk
  >> "!B64TMP!" echo YXRlLnNoLgojICAgVG8gZm9yY2UgdGhlIGNob2ljZSBmb3Igb25lIHJ1bjogIExPQ0FMX1NFQVJD
  >> "!B64TMP!" echo SF9FTkdJTkU9ZG9ja2VyIC4vaW5zdGFsbC1sb2NhbC1zZWFyY2guc2gKTE9DQUxfU0VBUkNIX0VO
  >> "!B64TMP!" echo R0lORT1wb2RtYW4KCiMgLS0tLSBTZWFyWE5HIGNvbmZpZy1mb2xkZXIgbW91bnQgKGluc3RhbGxl
  >> "!B64TMP!" echo ciBkZWNpZGVzOyBsZWF2ZSBhcyB3cml0dGVuKSAtLS0tCiMgICBTRUFSWE5HX01PVU5UX09QVFM9
  >> "!B64TMP!" echo LHogICAgICAgICAgICBob3N0cyB3aXRoIFNFTGludXggKEZlZG9yYSwgUkhFTCwgLi4uKTogcmVs
  >> "!B64TMP!" echo YWJlbHMKIyAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNvbmZpZy9zZWFyeG5n
  >> "!B64TMP!" echo IHNvIHRoZSBjb250YWluZXIgbWF5IHJlYWQgaXQuCiMgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBXaXRob3V0IGl0IFNlYXJYTkcgcmVzdGFydC1sb29wcyB3aXRoCiMgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiY2hvd24vY3Avc2VkIC4uLiBQZXJtaXNzaW9u
  >> "!B64TMP!" echo IGRlbmllZCIuIEVtcHR5IGVsc2V3aGVyZS4KIyAgIFNFQVJYTkdfRk9SQ0VfT1dORVJTSElQPWZh
  >> "!B64TMP!" echo bHNlICAgIHJvb3RsZXNzIFBvZG1hbjogc3RvcHMgU2VhclhORydzIGVudHJ5cG9pbnQgZnJvbQoj
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcmUtb3duaW5nIHRoZSBmb2xkZXIg
  >> "!B64TMP!" echo KGl0IHdvdWxkIGJlY29tZSBhIHN1Yi1VSUQgeW91CiMgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBjYW5ub3QgZWRpdCkuICJ0cnVlIiAodGhlIGltYWdlIGRlZmF1bHQpIGVsc2V3
  >> "!B64TMP!" echo aGVyZS4KU0VBUlhOR19NT1VOVF9PUFRTPQpTRUFSWE5HX0ZPUkNFX09XTkVSU0hJUD10cnVlCgoj
  >> "!B64TMP!" echo IC0tLS0gRmlyZWNyYXdsIGludGVybmFsIGNyZWRlbnRpYWxzIChpbnN0YWxsZXIgZ2VuZXJhdGVz
  >> "!B64TMP!" echo IHJhbmRvbSB2YWx1ZXMpIC0tLS0KQlVMTF9BVVRIX0tFWT1yZXBsYWNlLXdpdGgtNjQtY2hhci1y
  >> "!B64TMP!" echo YW5kb20taGV4ClBPU1RHUkVTX0RCPWZpcmVjcmF3bApQT1NUR1JFU19VU0VSPWZpcmVjcmF3bApQ
  >> "!B64TMP!" echo T1NUR1JFU19QQVNTV09SRD1yZXBsYWNlLXdpdGgtNjQtY2hhci1yYW5kb20taGV4ClJBQkJJVE1R
  >> "!B64TMP!" echo X1VTRVI9ZmlyZWNyYXdsClJBQkJJVE1RX1BBU1NXT1JEPXJlcGxhY2Utd2l0aC02NC1jaGFyLXJh
  >> "!B64TMP!" echo bmRvbS1oZXgKCiMgLS0tLSBCcm93c2VyIHJlbmRlcmluZyBlbmdpbmUgZm9yIEZpcmVjcmF3bCAo
  >> "!B64TMP!" echo aW5zdGFsbGVyIFN0ZXAgNCkgLS0tLQojICAgcGxheXdyaWdodCAoZGVmYXVsdCk6IGdoY3IuaW8v
  >> "!B64TMP!" echo ZmlyZWNyYXdsL3BsYXl3cmlnaHQtc2VydmljZQojICAgYnJvd3Nlcmxlc3M6ICAgICAgICAgIGdo
  >> "!B64TMP!" echo Y3IuaW8vYnJvd3Nlcmxlc3MvY2hyb21pdW0gKHN0ZWFsdGggbW9kZSwgYmV0dGVyCiMgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgIGJsb2NrIGF2b2lkYW5jZSBvbiBDbG91ZGZsYXJlLWZyb250ZWQg
  >> "!B64TMP!" echo c2l0ZXMpCiMgICBDT01QT1NFX1BST0ZJTEVTIHNlbGVjdHMgd2hpY2ggc2VydmljZSBhY3R1YWxs
  >> "!B64TMP!" echo eSBzdGFydHM7IFBMQVlXUklHSFRfTUlDUk9TRVJWSUNFX1VSTAojICAgbXVzdCBwb2ludCBhdCB0
  >> "!B64TMP!" echo aGUgc2FtZSBvbmUuIFRvIHN3aXRjaCBsYXRlciwgY2hhbmdlIGJvdGggbGluZXMgYW5kIHJ1biBV
  >> "!B64TMP!" echo cGRhdGUuYmF0L3VwZGF0ZS5zaC4KQ09NUE9TRV9QUk9GSUxFUz1wbGF5d3JpZ2h0ClBMQVlXUklH
  >> "!B64TMP!" echo SFRfTUlDUk9TRVJWSUNFX1VSTD1odHRwOi8vcGxheXdyaWdodC1zZXJ2aWNlOjMwMDAvc2NyYXBl
  >> "!B64TMP!" echo CgojIC0tLS0gQnJvd3Nlcmxlc3MgdG9rZW4gKG9ubHkgdXNlZCBpZiBDT01QT1NFX1BST0ZJTEVT
  >> "!B64TMP!" echo PWJyb3dzZXJsZXNzIGFib3ZlOyBpbnN0YWxsZXIgZ2VuZXJhdGVzIGEgcmFuZG9tIHZhbHVlIHJl
  >> "!B64TMP!" echo Z2FyZGxlc3MpIC0tLS0KQlJPV1NFUkxFU1NfVE9LRU49cmVwbGFjZS13aXRoLTY0LWNoYXItcmFu
  >> "!B64TMP!" echo ZG9tLWhleAoKIyAtLS0tIExvZ2dpbmcgLS0tLQpMT0dHSU5HX0xFVkVMPWluZm8KCiMgPT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT0KIyAgT3B0aW9uYWw6IGNvbm5lY3QgYSBsb2NhbCAob3IgcmVtb3RlKSBM
  >> "!B64TMP!" echo TE0gc28gRmlyZWNyYXdsJ3MgL3YxL2V4dHJhY3QgYW5kCiMgICJzdW1tYXJ5IiBmZWF0dXJlcyB3
  >> "!B64TMP!" echo b3JrLiBBbnkgT3BlbkFJLWNvbXBhdGlibGUgZW5kcG9pbnQgd2lsbCBkby4KIyAgTE0gU3R1ZGlv
  >> "!B64TMP!" echo IGlzIHRoZSByZWNvbW1lbmRlZCBkZWZhdWx0IChwcmlvcml0eSBvdmVyIE9sbGFtYSkuCiMgPT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT0KCiMgLS0tLSBPcHRpb24gQSAoUkVDT01NRU5ERUQpOiBMTSBTdHVk
  >> "!B64TMP!" echo aW8gLyBhbnkgT3BlbkFJLWNvbXBhdGlibGUgbG9jYWwgc2VydmVyIC0tLS0KIyAgIDEuIEluIExN
  >> "!B64TMP!" echo IFN0dWRpbzogRGV2ZWxvcGVyIHRhYiA+ICJTdGFydCBTZXJ2ZXIiIG9uIHBvcnQgMTIzNCwgbG9h
  >> "!B64TMP!" echo ZCBhIG1vZGVsLAojICAgICAgYW5kIEVOQUJMRSAiU2VydmUgb24gbG9jYWwgbmV0d29yayIgc28g
  >> "!B64TMP!" echo dGhlIEZpcmVjcmF3bCBjb250YWluZXIgY2FuIHJlYWNoIGl0LgojICAgMi4gTk9URTogT1BFTkFJ
  >> "!B64TMP!" echo X0JBU0VfVVJMIGlzIHJlYWQgSU5TSURFIHRoZSBGaXJlY3Jhd2wgY29udGFpbmVyLiBGcm9tIHRo
  >> "!B64TMP!" echo ZXJlLAojICAgICAgeW91ciBob3N0IG1hY2hpbmUgaXMgImhvc3QuZG9ja2VyLmludGVybmFsIiwg
  >> "!B64TMP!" echo Tk9UICJsb2NhbGhvc3QiLiBTbyB1c2U6CiMgT1BFTkFJX0JBU0VfVVJMPWh0dHA6Ly9ob3N0LmRv
  >> "!B64TMP!" echo Y2tlci5pbnRlcm5hbDoxMjM0L3YxCiMgT1BFTkFJX0FQSV9LRVk9bG0tc3R1ZGlvICAgICAgICAg
  >> "!B64TMP!" echo ICMgYW55IG5vbi1lbXB0eSBzdHJpbmc7IExNIFN0dWRpbyBpZ25vcmVzIGl0CiMgTU9ERUxfTkFN
  >> "!B64TMP!" echo RT1sb2NhbC1tb2RlbCAgICAgICAgICAgICMgdGhlIG1vZGVsIGlkIGxvYWRlZCBpbiBMTSBTdHVk
  >> "!B64TMP!" echo aW8KCiMgLS0tLSBPcHRpb24gQjogcmVtb3RlIE9wZW5BSS1jb21wYXRpYmxlIHNlcnZlciAodkxM
  >> "!B64TMP!" echo TSwgbGxhbWEuY3BwIHNlcnZlciwgZXRjLikgLS0tLQojIE9QRU5BSV9CQVNFX1VSTD1odHRwOi8v
  >> "!B64TMP!" echo MTkyLjE2OC4xLjUwOjgwMDAvdjEKIyBPUEVOQUlfQVBJX0tFWT1wbGFjZWhvbGRlcgojIE1PREVM
  >> "!B64TMP!" echo X05BTUU9eW91ci1tb2RlbC1pZAoKIyAtLS0tIE9wdGlvbiBDIChmYWxsYmFjayk6IE9sbGFtYSBv
  >> "!B64TMP!" echo biB0aGUgc2FtZSBob3N0IGFzIERvY2tlciAtLS0tCiMgT0xMQU1BX0JBU0VfVVJMPWh0dHA6Ly9o
  >> "!B64TMP!" echo b3N0LmRvY2tlci5pbnRlcm5hbDoxMTQzNC9hcGkKIyBNT0RFTF9OQU1FPXF3ZW4yLjU6N2IKIyBN
  >> "!B64TMP!" echo T0RFTF9FTUJFRERJTkdfTkFNRT1ub21pYy1lbWJlZC10ZXh0CgojID09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09CiMgIE9wdGlvbmFsOiBGaXJlY3Jhd2wgYWNjb3VudCAocGFpZCBjbG91ZCBzZXJ2aWNlKSBm
  >> "!B64TMP!" echo b3IgdGhlIGFjY291bnQtb25seQojICBsb2NhbC13ZWItc2VhcmNoIHRvb2xzIChyZXNlYXJjaCBh
  >> "!B64TMP!" echo Z2VudCwgaW50ZXJhY3QsIHBhcnNlLCBtb25pdG9ycywgcGFwZXIKIyAgcmVzZWFyY2gsIEdpdEh1
  >> "!B64TMP!" echo Yi9kZXZlbG9wZXIgc2VhcmNoKS4KIwojICBUaGUgaW5zdGFsbGVyIG9mZmVycyB0byB3cml0ZSB0
  >> "!B64TMP!" echo aGVzZSBmb3IgeW91IChhbnN3ZXIgJ3knIGF0IHRoZQojICAiQWRkIGEgRmlyZWNyYXdsIGFjY291
  >> "!B64TMP!" echo bnQ/IiBxdWVzdGlvbiwgdGhlbiBwYXN0ZSB5b3VyIGtleSkuIFdpdGhvdXQgdGhlbQojICB0aGUg
  >> "!B64TMP!" echo aW5zdGFsbGVyIHNraXBzIHRob3NlIHRvb2xzIGFuZCBpbnN0YWxscyBvbmx5IHRoZSBmcmVlIGxv
  >> "!B64TMP!" echo Y2FsIG9uZXMuCiMgIFRoZSBsb2NhbC13ZWItc2VhcmNoIHNjcmlwdHMgcmVhZCB0aGVzZSBrZXlz
  >> "!B64TMP!" echo IGZyb20gVEhJUyBmaWxlOwojICBGSVJFQ1JBV0xfQVBJX1VSTCAvIEZJUkVDUkFXTF9BUElfS0VZ
  >> "!B64TMP!" echo IGVudmlyb25tZW50IHZhcmlhYmxlcyBvdmVycmlkZSB0aGVtLgojICAoVGhlIERvY2tlciBjb250
  >> "!B64TMP!" echo YWluZXJzIGlnbm9yZSB0aGVzZSBrZXlzIGVudGlyZWx5LikKIyA9PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PQojIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYKIyBGSVJFQ1JB
  >> "!B64TMP!" echo V0xfQVBJX0tFWT1mYy15b3VyLWtleS1oZXJlCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\.env.example"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- README.md ---
set "NEED_B64=1"
if exist "!SRC!\README.md" (
  copy /Y "!SRC!\README.md" "!TARGET!\README.md" >nul 2>&1
  if exist "!TARGET!\README.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] README.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS160655574.b64"
  > "!B64TMP!" echo IyDwn5SNIExvY2FsIFNlYXJjaCDigJQgYSBwcml2YXRlIHdlYi1icm93c2luZyBzeXN0ZW0gZm9y
  >> "!B64TMP!" echo IEFJIG1vZGVscwoKKipTZWFyWE5HICsgRmlyZWNyYXdsICsgdGhlIGxvY2FsLXdlYi1zZWFyY2gg
  >> "!B64TMP!" echo YWdlbnQgc2tpbGwsIHJ1bm5pbmcgZW50aXJlbHkgb24geW91ciBtYWNoaW5lLCBiZWhpbmQgdHdv
  >> "!B64TMP!" echo IGxvY2FsIHBvcnRzLioqCgpHaXZlIGFueSBMTE0g4oCUIGEgbG9jYWwgbW9kZWwgaW4gTE0gU3R1
  >> "!B64TMP!" echo ZGlvLCBhIGNsb3VkIG1vZGVsLCBhbiBhZ2VudCwgYW4gTUNQCmNsaWVudCwgb3IgYSBwbGFpbiBj
  >> "!B64TMP!" echo aGF0IFVJIOKAlCB0aGUgYWJpbGl0eSB0byAqKnNlYXJjaCB0aGUgd2ViIGFuZCByZWFkIHBhZ2Vz
  >> "!B64TMP!" echo KioKd2l0aG91dCBzZW5kaW5nIGEgc2luZ2xlIHJlcXVlc3QgdG8gYSBwYWlkIHNjcmFwaW5nIEFQ
  >> "!B64TMP!" echo SS4gRXZlcnl0aGluZyBydW5zIGluCkRvY2tlciBvbiB5b3VyIGNvbXB1dGVyOyB5b3VyIHF1ZXJp
  >> "!B64TMP!" echo ZXMsIHJlc3VsdHMsIGFuZCBwYWdlIGNvbnRlbnRzIG5ldmVyIGxlYXZlCnlvdXIgbmV0d29yay4K
  >> "!B64TMP!" echo CnwgV2hhdCB8IFVSTCAoZGVmYXVsdCkgfCBQdXJwb3NlIHwKfC0tLS0tLXwtLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS18LS0tLS0tLS0tfAp8ICoqU2VhclhORyoqICB8IGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgIHwg
  >> "!B64TMP!" echo TWV0YXNlYXJjaCArIEpTT04gQVBJLiBBZ2dyZWdhdGVzIEdvb2dsZS9CaW5nL0R1Y2tEdWNrR28v
  >> "!B64TMP!" echo ZXRjLiB8CnwgKipGaXJlY3Jhd2wqKiB8IGBodHRwOi8vbG9jYWxob3N0Ojk5OTFgIHwgU2NyYXBl
  >> "!B64TMP!" echo IC8gY3Jhd2wgLyBtYXAgLyBzZWFyY2ggLyBleHRyYWN0IOKAlCByZXR1cm5zIGNsZWFuIE1hcmtk
  >> "!B64TMP!" echo b3duLiB8CnwgKipsb2NhbC13ZWItc2VhcmNoKiogfCBgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoYCB8IEJ1bmRsZWQgYWdlbnQgc2tpbGw6IHNlYXJjaCArIHJlYWQgKyBhdXRvLXN0
  >> "!B64TMP!" echo YXJ0IHRoZSBzdGFjay4gfAoKPiBCb3RoIHBvcnRzIGFyZSBmdWxseSBjb25maWd1cmFibGUgYXQg
  >> "!B64TMP!" echo aW5zdGFsbCB0aW1lLiBUaGUgZGVmYXVsdHMgKGA5OTkwYCBhbmQKPiBgOTk5MWApIGFyZSBjaG9z
  >> "!B64TMP!" echo ZW4gdG8gYXZvaWQgY2xhc2hpbmcgd2l0aCBjb21tb24gZGV2IHNlcnZlcnMuCgotLS0KCiMjIFRh
  >> "!B64TMP!" echo YmxlIG9mIGNvbnRlbnRzCgoxLiBbV2hhdCB5b3UgZ2V0XSgjd2hhdC15b3UtZ2V0KQoyLiBbUmVx
  >> "!B64TMP!" echo dWlyZW1lbnRzXSgjcmVxdWlyZW1lbnRzKQozLiBbUXVpY2sgc3RhcnQgKG9uZS1jbGljayBpbnN0
  >> "!B64TMP!" echo YWxsKV0oI3F1aWNrLXN0YXJ0LW9uZS1jbGljay1pbnN0YWxsKQo0LiBbTWFuYWdpbmcgdGhlIHN0
  >> "!B64TMP!" echo YWNrXSgjbWFuYWdpbmctdGhlLXN0YWNrKQo1LiBbSG93IGl0IGZpdHMgdG9nZXRoZXJdKCNob3ct
  >> "!B64TMP!" echo aXQtZml0cy10b2dldGhlcikKNi4gW1VzaW5nIGl0IHdpdGggQUkgbW9kZWxzXSgjdXNpbmctaXQt
  >> "!B64TMP!" echo d2l0aC1haS1tb2RlbHMpCiAgIC0gW0EuIFRoZSBidW5kbGVkIGxvY2FsLXdlYi1zZWFyY2ggc2tp
  >> "!B64TMP!" echo bGwgKHJlY29tbWVuZGVkKV0oI2EtdGhlLWJ1bmRsZWQtbG9jYWwtd2ViLXNlYXJjaC1za2lsbC1y
  >> "!B64TMP!" echo ZWNvbW1lbmRlZCkKICAgLSBbQi4gRGlyZWN0IFNlYXJYTkcgSlNPTiBBUEldKCNiLWRpcmVjdC1z
  >> "!B64TMP!" echo ZWFyeG5nLWpzb24tYXBpKQogICAtIFtDLiBEaXJlY3QgRmlyZWNyYXdsIFJFU1QgQVBJXSgjYy1k
  >> "!B64TMP!" echo aXJlY3QtZmlyZWNyYXdsLXJlc3QtYXBpKQogICAtIFtELiBDb25uZWN0IGFuIExMTSAoTE0gU3R1
  >> "!B64TMP!" echo ZGlvLCBldGMuKV0oI2QtY29ubmVjdC1hbi1sbG0tbG0tc3R1ZGlvLWV0YykKICAgLSBbRS4gVmlh
  >> "!B64TMP!" echo IGFuIE1DUCBzZXJ2ZXJdKCNlLXZpYS1hbi1tY3Atc2VydmVyKQogICAtIFtGLiBWaWEgcHJvbXB0
  >> "!B64TMP!" echo aW5nIChhbnkgY2hhdCBVSSldKCNmLXZpYS1wcm9tcHRpbmctYW55LWNoYXQtdWkpCiAgIC0gW0cu
  >> "!B64TMP!" echo IEdVSSBpbnRlZ3JhdGlvbnNdKCNnLWd1aS1pbnRlZ3JhdGlvbnMpCjcuIFtDb25maWd1cmF0aW9u
  >> "!B64TMP!" echo IHJlZmVyZW5jZV0oI2NvbmZpZ3VyYXRpb24tcmVmZXJlbmNlKQo4LiBbVHJvdWJsZXNob290aW5n
  >> "!B64TMP!" echo XSgjdHJvdWJsZXNob290aW5nKQo5LiBbVXBkYXRpbmcgJiB1bmluc3RhbGxpbmddKCN1cGRhdGlu
  >> "!B64TMP!" echo Zy0tdW5pbnN0YWxsaW5nKQoxMC4gW0RldmVsb3BtZW50OiBmdWxsIGRldiByaWcgKHJlYnVpbGRp
  >> "!B64TMP!" echo bmcgZXZlcnl0aGluZyldKCNkZXZlbG9wbWVudC1mdWxsLWRldi1yaWctcmVidWlsZGluZy1ldmVy
  >> "!B64TMP!" echo eXRoaW5nKQoxMS4gW1NlY3VyaXR5IG5vdGVzXSgjc2VjdXJpdHktbm90ZXMpCjEyLiBbQ3JlZGl0
  >> "!B64TMP!" echo cyAmIGxpY2Vuc2VzXSgjY3JlZGl0cy0tbGljZW5zZXMpCgotLS0KCiMjIFdoYXQgeW91IGdldAoK
  >> "!B64TMP!" echo QSBzaW5nbGUgRG9ja2VyIENvbXBvc2Ugc3RhY2sgb2Ygc2l4IHJ1bm5pbmcgc2VydmljZXMgb24g
  >> "!B64TMP!" echo YSBwcml2YXRlIGJyaWRnZQpuZXR3b3JrIChzZXZlbiBhcmUgZGVmaW5lZCwgYnV0IHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsZXIgb25seSBzdGFydHMgb25lIG9mIHRoZSB0d28KYnJvd3NlciBlbmdpbmVzIGJlbG93KSwg
  >> "!B64TMP!" echo KipwbHVzKiogYSByZWFkeS1tYWRlIGFnZW50IHNraWxsIHRoYXQgdGllcyBpdCBhbGwKdG9nZXRo
  >> "!B64TMP!" echo ZXI6Cgp8IFNlcnZpY2UgfCBJbWFnZSB8IFJvbGUgfAp8LS0tLS0tLS0tfC0tLS0tLS18LS0tLS0t
  >> "!B64TMP!" echo fAp8ICoqc2VhcnhuZyoqIHwgYHNlYXJ4bmcvc2VhcnhuZzpsYXRlc3RgIHwgTWV0YXNlYXJjaCBl
  >> "!B64TMP!" echo bmdpbmUgd2l0aCAqKkpTT04gb3V0cHV0IGVuYWJsZWQqKiBhbmQgdGhlIHJhdGUtbGltaXRlciAq
  >> "!B64TMP!" echo KmRpc2FibGVkKiosIHNvIG1vZGVscyBjYW4gcXVlcnkgaXQgcHJvZ3JhbW1hdGljYWxseS4gfAp8
  >> "!B64TMP!" echo ICoqZmlyZWNyYXdsKiogfCBgZ2hjci5pby9maXJlY3Jhd2wvZmlyZWNyYXdsOmxhdGVzdGAgfCBU
  >> "!B64TMP!" echo aGUgc2NyYXBpbmcvY3Jhd2xpbmcvc2VhcmNoIEFQSS4gUnVucyB3aXRoIGBVU0VfREJfQVVUSEVO
  >> "!B64TMP!" echo VElDQVRJT049ZmFsc2VgIOKGkiAqKm5vIEFQSSBrZXkgbmVlZGVkKiogZm9yIGxvY2FsIHVzZS4g
  >> "!B64TMP!" echo fAp8ICoqcGxheXdyaWdodC1zZXJ2aWNlKiogKihkZWZhdWx0IGVuZ2luZSkqIHwgYGdoY3IuaW8v
  >> "!B64TMP!" echo ZmlyZWNyYXdsL3BsYXl3cmlnaHQtc2VydmljZTpsYXRlc3RgIHwgSGVhZGxlc3MgQ2hyb21pdW0g
  >> "!B64TMP!" echo Zm9yIEphdmFTY3JpcHQtcmVuZGVyZWQgcGFnZXMg4oCUIHRoZSBjbGFzc2ljIEZpcmVjcmF3bCBl
  >> "!B64TMP!" echo bmdpbmUuIFN0YXJ0cyB3aGVuIHRoZSBpbnN0YWxsZXIncyBTdGVwIDQgYW5zd2VyIGlzIFBsYXl3
  >> "!B64TMP!" echo cmlnaHQgKHRoZSBkZWZhdWx0KS4gfAp8ICoqYnJvd3Nlcmxlc3MqKiAqKGFsdGVybmF0ZSBlbmdp
  >> "!B64TMP!" echo bmUpKiB8IGBnaGNyLmlvL2Jyb3dzZXJsZXNzL2Nocm9taXVtOmxhdGVzdGAgfCBTdGVhbHRoIGhl
  >> "!B64TMP!" echo YWRsZXNzIENocm9taXVtIChCcm93c2VybGVzcyBDRSwgYERFRkFVTFRfU1RFQUxUSD10cnVlYCkg
  >> "!B64TMP!" echo Zm9yIEphdmFTY3JpcHQtcmVuZGVyZWQgcGFnZXM7IGJldHRlciBhdCBhdm9pZGluZyBDbG91ZGZs
  >> "!B64TMP!" echo YXJlLXN0eWxlIGJvdCBjaGVja3MuIFN0YXJ0cyBpbnN0ZWFkIG9mIFBsYXl3cmlnaHQgd2hlbiBT
  >> "!B64TMP!" echo dGVwIDQgaXMgYW5zd2VyZWQgKip5KiouIHwKfCAqKnJlZGlzKiogfCBgcmVkaXM6YWxwaW5lYCB8
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBqb2IgcXVldWUuIHwKfCAqKnJhYmJpdG1xKiogfCBgcmFiYml0bXE6My1tYW5h
  >> "!B64TMP!" echo Z2VtZW50YCB8IEZpcmVjcmF3bCBtZXNzYWdlIGJyb2tlci4gfAp8ICoqbnVxLXBvc3RncmVzKiog
  >> "!B64TMP!" echo fCBgZ2hjci5pby9maXJlY3Jhd2wvbnVxLXBvc3RncmVzOmxhdGVzdGAgfCBGaXJlY3Jhd2wgam9i
  >> "!B64TMP!" echo LXN0YXRlIERCIChwZ19jcm9uIGVuYWJsZWQpLiB8CgpPbiB0b3Agb2YgdGhlIGNvbnRhaW5lcnMs
  >> "!B64TMP!" echo IHRoZSBpbnN0YWxsZXIgYnVuZGxlcyAqKmxvY2FsLXdlYi1zZWFyY2gqKiDigJQgYSBza2lsbCBm
  >> "!B64TMP!" echo b3IKYWdlbnRzIHRoYXQgbG9hZCBza2lsbHMgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9gIChgQzpc
  >> "!B64TMP!" echo VXNlcnNcWW91XC5hZ2VudHNcc2tpbGxzXGAKb24gV2luZG93cykuIEl0IGdpdmVzIHRoZSBhZ2Vu
  >> "!B64TMP!" echo dCBhIGNvbXBsZXRlIHdlYi1yZXNlYXJjaCB3b3JrZmxvdzogc2VhcmNoIHZpYQpTZWFyWE5HLCBy
  >> "!B64TMP!" echo ZWFkIHBhZ2VzIHZpYSBGaXJlY3Jhd2wsIGFuZCBldmVuIHN0YXJ0IHRoZSBEb2NrZXIgc3RhY2sK
  >> "!B64TMP!" echo YXV0b21hdGljYWxseSB3aGVuIGl0J3MgZG93bi4gU2VlIFtzZWN0aW9uIEFdKCNhLXRoZS1idW5k
  >> "!B64TMP!" echo bGVkLWxvY2FsLXdlYi1zZWFyY2gtc2tpbGwtcmVjb21tZW5kZWQpLgoKT25seSAqKnR3byBob3N0
  >> "!B64TMP!" echo IHBvcnRzKiogYXJlIHB1Ymxpc2hlZCAoYDk5OTBgIGFuZCBgOTk5MWAgYnkgZGVmYXVsdCkuIEV2
  >> "!B64TMP!" echo ZXJ5dGhpbmcKZWxzZSBzdGF5cyBvbiB0aGUgcHJpdmF0ZSBgbG9jYWwtc2VhcmNoLW5ldGAgYnJp
  >> "!B64TMP!" echo ZGdlIG5ldHdvcmsuIEZpcmVjcmF3bCdzCmAvdjEvc2VhcmNoYCBlbmRwb2ludCBpcyBhdXRvbWF0
  >> "!B64TMP!" echo aWNhbGx5IHdpcmVkIHRvIFNlYXJYTkcgaW50ZXJuYWxseSwgc28gYSBzaW5nbGUKRmlyZWNyYXds
  >> "!B64TMP!" echo IGNhbGwgY2FuIGJvdGggc2VhcmNoICphbmQqIGZldGNoIGZ1bGwgcGFnZSBjb250ZW50LgoKLS0t
  >> "!B64TMP!" echo CgojIyBSZXF1aXJlbWVudHMKCi0gKipEb2NrZXIqKiB3aXRoIHRoZSAqKkNvbXBvc2UgdjIgcGx1
  >> "!B64TMP!" echo Z2luKiogKGBkb2NrZXIgY29tcG9zZWApIOKAlCAqKm9yIFBvZG1hbioqIChMaW51eC9tYWNPUykg
  >> "!B64TMP!" echo d2l0aCBhIGNvbXBvc2UgcHJvdmlkZXIuCiAgLSBXaW5kb3dzOiBbRG9ja2VyIERlc2t0b3BdKGh0
  >> "!B64TMP!" echo dHBzOi8vd3d3LmRvY2tlci5jb20vcHJvZHVjdHMvZG9ja2VyLWRlc2t0b3AvKQogIC0gbWFjT1M6
  >> "!B64TMP!" echo IFtEb2NrZXIgRGVza3RvcF0oaHR0cHM6Ly93d3cuZG9ja2VyLmNvbS9wcm9kdWN0cy9kb2NrZXIt
  >> "!B64TMP!" echo ZGVza3RvcC8pLCBvciBQb2RtYW4gKGBicmV3IGluc3RhbGwgcG9kbWFuIGRvY2tlci1jb21wb3Nl
  >> "!B64TMP!" echo YCwgdGhlbiBgcG9kbWFuIG1hY2hpbmUgaW5pdCAmJiBwb2RtYW4gbWFjaGluZSBzdGFydGApCiAg
  >> "!B64TMP!" echo LSBMaW51eCwgRG9ja2VyOiBbRG9ja2VyIEVuZ2luZV0oaHR0cHM6Ly9kb2NzLmRvY2tlci5jb20v
  >> "!B64TMP!" echo ZW5naW5lL2luc3RhbGwvKSArIHRoZSBgZG9ja2VyLWNvbXBvc2UtcGx1Z2luYCBwYWNrYWdlLiBB
  >> "!B64TMP!" echo ZGQgeW91ciB1c2VyIHRvIHRoZSBgZG9ja2VyYCBncm91cCBzbyB5b3UgZG9uJ3QgbmVlZCBgc3Vk
  >> "!B64TMP!" echo b2AuCiAgLSBMaW51eCwgUG9kbWFuIChGZWRvcmEgLyBSSEVMIC8gRGViaWFuIC8gVWJ1bnR1KTog
  >> "!B64TMP!" echo YHN1ZG8gZG5mIGluc3RhbGwgcG9kbWFuIGRvY2tlci1jb21wb3NlYCAoRGViaWFuL1VidW50dTog
  >> "!B64TMP!" echo YHN1ZG8gYXB0IGluc3RhbGwgcG9kbWFuIGRvY2tlci1jb21wb3NlLXYyYCkuIEJvdGggY29tcG9z
  >> "!B64TMP!" echo ZSBwcm92aWRlcnMgd29yayDigJQgQ29tcG9zZSB2MiAoYGRvY2tlci1jb21wb3NlYCkgYW5kIGBw
  >> "!B64TMP!" echo b2RtYW4tY29tcG9zZWAgKHRlc3RlZCB3aXRoIDEuNi4wKS4gUm9vdGxlc3MgaXMgZmluZS4KICAt
  >> "!B64TMP!" echo ICoqSWYgYm90aCBQb2RtYW4gYW5kIERvY2tlciBhcmUgaW5zdGFsbGVkLCB0aGUgTGludXgvbWFj
  >> "!B64TMP!" echo T1MgaW5zdGFsbGVyIHVzZXMgUG9kbWFuLioqIEZvcmNlIHRoZSBvdGhlciBvbmUgd2l0aCBgTE9D
  >> "!B64TMP!" echo QUxfU0VBUkNIX0VOR0lORT1kb2NrZXIgLi9pbnN0YWxsLWxvY2FsLXNlYXJjaC5zaGAuIFRoZSBp
  >> "!B64TMP!" echo bnN0YWxsZXIgcmVjb3JkcyBpdHMgY2hvaWNlIGluIGAuZW52YCAoYExPQ0FMX1NFQVJDSF9FTkdJ
  >> "!B64TMP!" echo TkVgKSBzbyBgcnVuLnNoYCAvIGB1cGRhdGUuc2hgIGtlZXAgdXNpbmcgdGhlIHNhbWUgZW5naW5l
  >> "!B64TMP!" echo LiBUaGUgV2luZG93cyBpbnN0YWxsZXIgdXNlcyBEb2NrZXIgRGVza3RvcC4KLSAqKn41IEdCIGZy
  >> "!B64TMP!" echo ZWUgZGlzayoqIGZvciBpbWFnZXMgYW5kIGRhdGEuCi0gKio4IEdCIFJBTSAvIDQgQ1BVIGNvcmVz
  >> "!B64TMP!" echo KiogcmVjb21tZW5kZWQgKEZpcmVjcmF3bCBwbHVzIGl0cyBicm93c2VyIGVuZ2luZSDigJQgUGxh
  >> "!B64TMP!" echo eXdyaWdodCBvciBCcm93c2VybGVzcyDigJQgaXMgdGhlIGhlYXZ5IHBhcnQ7IHJlZHVjZSByZXNv
  >> "!B64TMP!" echo dXJjZSBsaW1pdHMgaW4gYGRvY2tlci1jb21wb3NlLnltbGAgZm9yIHNtYWxsZXIgaG9zdHMpLgot
  >> "!B64TMP!" echo ICoqUHl0aG9uIDMuOCsqKiBmb3IgdGhlIGJ1bmRsZWQgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCBz
  >> "!B64TMP!" echo Y3JpcHRzIChvcHRpb25hbCBidXQgcmVjb21tZW5kZWQg4oCUIGl0J3MgdGhlIGVhc2llc3Qgd2F5
  >> "!B64TMP!" echo IHRvIHVzZSB0aGUgc3RhY2spLgotICooT3B0aW9uYWwsIGZvciBGaXJlY3Jhd2wgQUkgZmVhdHVy
  >> "!B64TMP!" echo ZXMpKiAqKkxNIFN0dWRpbyoqIG9yIGFueSBPcGVuQUktY29tcGF0aWJsZSBlbmRwb2ludCwgbG9j
  >> "!B64TMP!" echo YWwgb3IgcmVtb3RlIOKAlCBzZWUgW3NlY3Rpb24gRF0oI2QtY29ubmVjdC1hbi1sbG0tbG0tc3R1
  >> "!B64TMP!" echo ZGlvLWV0YykuCi0gKihPcHRpb25hbCwgZm9yIE1DUCkqICoqTm9kZS5qcyAxOCsqKiBzbyBgbnB4
  >> "!B64TMP!" echo IGZpcmVjcmF3bC1tY3BgIHdvcmtzLgoKVmVyaWZ5IHlvdXIgZW5naW5lIGlzIHJlYWR5OgoKYGBg
  >> "!B64TMP!" echo YmFzaApkb2NrZXIgaW5mbyAgICAgICAgICAgICMgZW5naW5lIGlzIHJ1bm5pbmcgICAgICAgIChQ
  >> "!B64TMP!" echo b2RtYW46IHBvZG1hbiBpbmZvKQpkb2NrZXIgY29tcG9zZSB2ZXJzaW9uICMgdjIgaXMgaW5zdGFs
  >> "!B64TMP!" echo bGVkICAgICAgICAgKFBvZG1hbjogcG9kbWFuIGNvbXBvc2UgdmVyc2lvbikKYGBgCgotLS0KCiMj
  >> "!B64TMP!" echo IFF1aWNrIHN0YXJ0IChvbmUtY2xpY2sgaW5zdGFsbCkKCj4gKipUaGUgaW5zdGFsbGVyIGlzIHNl
  >> "!B64TMP!" echo bGYtY29udGFpbmVkLioqIEV2ZXJ5IGZpbGUgaXQgbmVlZHMgKGBkb2NrZXItY29tcG9zZS55bWxg
  >> "!B64TMP!" echo LCBgY29uZmlnL3NlYXJ4bmcvc2V0dGluZ3MueW1sYCwgYC5lbnYuZXhhbXBsZWAsIHRoZSBidW5k
  >> "!B64TMP!" echo bGVkIGBsb2NhbC13ZWItc2VhcmNoYCBza2lsbCwgYWxsIHRoZSBydW4vc3RvcC91cGRhdGUvdW5p
  >> "!B64TMP!" echo bnN0YWxsIHNjcmlwdHMsIHRoaXMgUkVBRE1FLCBhbmQgZXZlbiB0aGUgKm90aGVyKiBwbGF0Zm9y
  >> "!B64TMP!" echo bSdzIGluc3RhbGxlcikgaXMgZW1iZWRkZWQgaW5zaWRlIGl0LiBEb3dubG9hZCAqKmBpbnN0YWxs
  >> "!B64TMP!" echo LWxvY2FsLXNlYXJjaC5iYXRgKiogKFdpbmRvd3MpIG9yICoqYGluc3RhbGwtbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo LnNoYCoqIChMaW51eC9tYWNPUykgb24gaXRzIG93biBhbmQgdGhlIGluc3RhbGxlciB3aWxsIHBy
  >> "!B64TMP!" echo b2R1Y2UgYSBjb21wbGV0ZSwgd29ya2luZyBmb2xkZXIgYW5kIGEgcnVuIHRoZSBzdGFjay4KClJ1
  >> "!B64TMP!" echo biAqKm9uZSoqIGluc3RhbGxlciBmb3IgeW91ciBwbGF0Zm9ybS4gRmlyc3QgaXQgYXNrcyB3aGlj
  >> "!B64TMP!" echo aCBzZXR1cCB5b3Ugd2FudCDigJQKdHlwZSAqKjEqKiwgKioyKiogb3IgKiozKiogKG9yIHByZXNz
  >> "!B64TMP!" echo ICoqRW50ZXIqKiBmb3IgKioxKiopOgoKfCBDaG9pY2UgICAgICAgICAgfCBTZXR1cCAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgfCBXaGF0IGl0IGRvZXMgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB8CnwgLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tIHwgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIHwgLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0gfAp8ICoqMSoqIChkZWZhdWx0KSB8IE1pbmltYWwgaW5zdGFsbGF0aW9u
  >> "!B64TMP!" echo ICAgICB8IERlZmF1bHQgZm9sZGVyLCBTZWFyWE5HIG9uIGA5OTkwYCwgRmlyZWNyYXdsIG9uIGA5
  >> "!B64TMP!" echo OTkxYCwgdGhlIFBsYXl3cmlnaHQgYnJvd3NlciBlbmdpbmUsIG5vIHF1ZXN0aW9ucyBhdCBhbGws
  >> "!B64TMP!" echo IG5vIExMTSwgbm8gRmlyZWNyYXdsIGFjY291bnQ6IGEgdHJ1ZSBvbmUtY2xpY2sgaW5zdGFsbC4g
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHwKfCAqKjIqKiAgICAgICAg
  >> "!B64TMP!" echo ICAgfCBNaW5pbWFsICsgTExNIGV4dHJhY3Rpb24gfCBUaGUgc2FtZSBkZWZhdWx0cywgcGx1cyB0
  >> "!B64TMP!" echo aHJlZSBxdWVzdGlvbnMgdG8gY29ubmVjdCBhbiBMTE0gKGJhc2UgVVJMLCBBUEkga2V5LCBtb2Rl
  >> "!B64TMP!" echo bCkuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICB8CnwgKiozKiogICAgICAgICAgIHwgRnVsbCBpbnN0YWxsYXRpb24gICAgICAgIHwg
  >> "!B64TMP!" echo VGhlIGZ1bGwgc2l4LXN0ZXAgc2V0dXAg4oCUIGluc3RhbGwgZm9sZGVyLCBTZWFyWE5HIHBvcnQs
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBwb3J0LCBhIGJyb3dzZXIgcmVuZGVyaW5nIGVuZ2luZSAoUGxheXdyaWdodCBv
  >> "!B64TMP!" echo ciBCcm93c2VybGVzcyksIChvcHRpb25hbGx5KSBhbiBMTE0sIGFuZCAob3B0aW9uYWxseSkgYSBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgYWNjb3VudCDigJQgd2l0aCB0aGUgc2FtZSBkZWZhdWx0cyBvZmZlcmVkIGF0IGVh
  >> "!B64TMP!" echo Y2ggc3RlcCBpZiB5b3UganVzdCBwcmVzcyAqKkVudGVyKiouIHwKCkVpdGhlciB3YXkgaXQgdGhl
  >> "!B64TMP!" echo biBnZW5lcmF0ZXMKY3J5cHRvZ3JhcGhpY2FsbHktc2VjdXJlIGNyZWRlbnRpYWxzLCB3cml0ZXMg
  >> "!B64TMP!" echo eW91ciBgLmVudmAsICoqaW5zdGFsbHMgdGhlCmxvY2FsLXdlYi1zZWFyY2ggc2tpbGwqKiwgcHVs
  >> "!B64TMP!" echo bHMgdGhlIGltYWdlcywgYW5kIHN0YXJ0cyB0aGUgc3RhY2suCgo+ICoqRW5naW5lIGlzbid0IHJ1
  >> "!B64TMP!" echo bm5pbmc/KiogTm8gcHJvYmxlbSDigJQgdGhlIGluc3RhbGxlciBzdGFydHMgaXQgZm9yIHlvdTog
  >> "!B64TMP!" echo aXQKPiBsYXVuY2hlcyBEb2NrZXIgRGVza3RvcCAoV2luZG93cy9tYWNPUyksIHRoZSBEb2NrZXIg
  >> "!B64TMP!" echo c2VydmljZQo+IChgc3lzdGVtY3RsYC9gc2VydmljZWAsIExpbnV4KSBvciB0aGUgUG9kbWFuIG1h
  >> "!B64TMP!" echo Y2hpbmUgKG1hY09TKSBhbmQgd2FpdHMgdXAgdG8KPiA1IG1pbnV0ZXMgZm9yIHRoZSBlbmdpbmUg
  >> "!B64TMP!" echo d2hpbGUgeW91IGFuc3dlciB0aGUgcHJvbXB0cy4gKE92ZXJyaWRlIHRoZSB3YWl0IHdpdGgKPiB0
  >> "!B64TMP!" echo aGUgYExPQ0FMX1NFQVJDSF9ET0NLRVJfVElNRU9VVGAgZW52IHZhciwgaW4gc2Vjb25kcy4pIFJv
  >> "!B64TMP!" echo b3RsZXNzIFBvZG1hbiBvbgo+IExpbnV4IGhhcyBubyBkYWVtb24gdG8gc3RhcnQuCgojIyMgV2lu
  >> "!B64TMP!" echo ZG93cwoKMS4gSW5zdGFsbCBbRG9ja2VyIERlc2t0b3BdKGh0dHBzOi8vd3d3LmRvY2tlci5jb20v
  >> "!B64TMP!" echo cHJvZHVjdHMvZG9ja2VyLWRlc2t0b3AvKSDigJQgbm8gbmVlZCB0byBvcGVuIGl0IGZpcnN0OyB0
  >> "!B64TMP!" echo aGUgaW5zdGFsbGVyIGxhdW5jaGVzIGl0IGF1dG9tYXRpY2FsbHkuCjIuIERvdWJsZS1jbGljayAq
  >> "!B64TMP!" echo KmBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXRgKiogKG9yIHJ1biBpdCBmcm9tIGEgdGVybWluYWwp
  >> "!B64TMP!" echo LgoKYGBgCj09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PQogIFNldHVwIHR5cGUKPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09CiAgMSkgTWluaW1hbCBpbnN0YWxsYXRpb24KICAy
  >> "!B64TMP!" echo KSBNaW5pbWFsICsgTExNIGV4dHJhY3Rpb24KICAzKSBGdWxsIGluc3RhbGxhdGlvbgogIERlZmF1
  >> "!B64TMP!" echo bHRzOiBDOlxVc2Vyc1xZb3VcbG9jYWwtc2VhcmNoLCBTZWFyWE5HIDk5OTAsIEZpcmVjcmF3bCA5
  >> "!B64TMP!" echo OTkxLAogIFBsYXl3cmlnaHQgZW5naW5lLCBubyBGaXJlY3Jhd2wgYWNjb3VudC4KICBDaG9vc2Ug
  >> "!B64TMP!" echo MSwgMiBvciAzIFtFbnRlciA9IDFdOgpgYGAKCioqMSoqIHNraXBzIGV2ZXJ5IHF1ZXN0aW9uIGFu
  >> "!B64TMP!" echo ZCBpbnN0YWxscy4gKioyKiogYXNrcyBvbmx5IGZvciB0aGUgTExNIChiYXNlIFVSTCwKQVBJIGtl
  >> "!B64TMP!" echo eSwgbW9kZWwpLCB0aGVuIGluc3RhbGxzLiAqKjMqKiB3YWxrcyB0aHJvdWdoIHRoZSBmdWxsIHNl
  >> "!B64TMP!" echo dHVwOgoKYGBgCi0tLSBTdGVwIDEgb2YgNjogSW5zdGFsbCBsb2NhdGlvbiAtLS0tLS0tLS0tCiAg
  >> "!B64TMP!" echo VGFyZ2V0IGZvbGRlciBbcHJlc3MgRW50ZXIgZm9yIGRlZmF1bHRdOiAgICAgICAgICAgICMgQzpc
  >> "!B64TMP!" echo VXNlcnNcWW91XGxvY2FsLXNlYXJjaAotLS0gU3RlcCAyIG9mIDY6IFNlYXJYTkcgcG9ydCAoZGVm
  >> "!B64TMP!" echo YXVsdCA5OTkwKSAtLS0tLS0KICBQb3J0IGZvciBTZWFyWE5HIFtwcmVzcyBFbnRlciBmb3IgOTk5
  >> "!B64TMP!" echo MF06IDk5OTAKLS0tIFN0ZXAgMyBvZiA2OiBGaXJlY3Jhd2wgcG9ydCAoZGVmYXVsdCA5OTkxKSAt
  >> "!B64TMP!" echo LS0tCiAgUG9ydCBmb3IgRmlyZWNyYXdsIFtwcmVzcyBFbnRlciBmb3IgOTk5MV06IDk5OTEKLS0t
  >> "!B64TMP!" echo IFN0ZXAgNCBvZiA2OiBCcm93c2VyIHJlbmRlcmluZyBlbmdpbmUgKGRlZmF1bHQ6IFBsYXl3cmln
  >> "!B64TMP!" echo aHQpIC0tLQogIFVzZSBCcm93c2VybGVzcyBpbnN0ZWFkIG9mIFBsYXl3cmlnaHQ/IFt5L05dOiAg
  >> "!B64TMP!" echo ICAgICAgICMgZGVmYXVsdDogUGxheXdyaWdodCwgc2VlIGJlbG93Ci0tLSBTdGVwIDUgb2YgNjog
  >> "!B64TMP!" echo TExNIChvcHRpb25hbCkgLS0tLS0tLS0tLS0tLS0tLS0tLQogIENvbm5lY3QgTExNIG5vdz8gW3kv
  >> "!B64TMP!" echo Tl06ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICMgZGVmYXVsdDogbm8sIHNlZSBzZWN0
  >> "!B64TMP!" echo aW9uIEQKLS0tIFN0ZXAgNiBvZiA2OiBGaXJlY3Jhd2wgYWNjb3VudCAob3B0aW9uYWwpIC0tLS0t
  >> "!B64TMP!" echo CiAgQWRkIGEgRmlyZWNyYXdsIGFjY291bnQgbm93PyBbeS9OXTogbiAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IyBkZWZhdWx0OiBza2lwLCBzZWUgYmVsb3cKYGBgCgojIyMgTGludXggJiBtYWNPUwoKYGBgYmFz
  >> "!B64TMP!" echo aApjaG1vZCAreCBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaAouL2luc3RhbGwtbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo LnNoCmBgYAoKVGhlIHByb21wdHMgYXJlIHRoZSBzYW1lLiBEZWZhdWx0czogaW5zdGFsbCB0byBg
  >> "!B64TMP!" echo fi9sb2NhbC1zZWFyY2hgLCBTZWFyWE5HIG9uCmA5OTkwYCwgRmlyZWNyYXdsIG9uIGA5OTkxYCwg
  >> "!B64TMP!" echo UGxheXdyaWdodCBhcyB0aGUgYnJvd3NlciBlbmdpbmUsIG5vIEZpcmVjcmF3bAphY2NvdW50IChh
  >> "!B64TMP!" echo bmQgYW4gTExNIG9ubHkgaWYgeW91IHBpY2sgc2V0dXAgKioyKiogb3IgYW5zd2VyICoqeSoqIGlu
  >> "!B64TMP!" echo IHNldHVwICoqMyoqKS4gQSBzdG9wcGVkIGVuZ2luZSBpcyBzdGFydGVkIGF1dG9tYXRpY2FsbHkK
  >> "!B64TMP!" echo KERvY2tlciBEZXNrdG9wIC8gUG9kbWFuIG1hY2hpbmUgb24gbWFjT1MsIGBzeXN0ZW1jdGxgL2Bz
  >> "!B64TMP!" echo ZXJ2aWNlYCBvbiBMaW51eCkuCgpUaGUgaW5zdGFsbGVyICoqcHJlZmVycyBQb2RtYW4qKiB3aGVu
  >> "!B64TMP!" echo IGl0IGlzIGluc3RhbGxlZCAoZXZlbiBpZiBEb2NrZXIgaXMgdG9vKSwKcHVsbHMgZXZlcnkgaW1h
  >> "!B64TMP!" echo Z2Ugb25seSBmcm9tICoqRG9ja2VyIEh1YiAoYGRvY2tlci5pb2ApIGFuZCBHSENSIChgZ2hjci5p
  >> "!B64TMP!" echo b2ApKiog4oCUCnRoZSBjb21wb3NlIGZpbGUgdXNlcyBmdWxseS1xdWFsaWZpZWQgbmFtZXMsIHNv
  >> "!B64TMP!" echo IFBvZG1hbiBuZXZlciBhc2tzIHdoaWNoIHJlZ2lzdHJ5CnRvIHVzZSDigJQgYW5kLCBvbmNlIHRo
  >> "!B64TMP!" echo ZSBzdGFjayBpcyB1cCwgKipjaGVja3MgdGhhdCBTZWFyWE5HIHJlYWxseSBhbnN3ZXJzKiosCnBy
  >> "!B64TMP!" echo aW50aW5nIGl0cyBjb250YWluZXIgc3RhdGUgYW5kIGxhc3QgbG9nIGxpbmVzIHdoZW4gaXQgZG9l
  >> "!B64TMP!" echo cyBub3QuIE9uClNFTGludXggaG9zdHMgKEZlZG9yYSwgUkhFTCwg4oCmKSBhbmQgd2l0aCByb290
  >> "!B64TMP!" echo bGVzcyBQb2RtYW4gaXQgYWxzbyBzZXRzIGhvdwpTZWFyWE5HJ3MgY29uZmlnIGZvbGRlciBpcyBt
  >> "!B64TMP!" echo b3VudGVkIChzZWUgYFNFQVJYTkdfTU9VTlRfT1BUU2AgLwpgU0VBUlhOR19GT1JDRV9PV05FUlNI
  >> "!B64TMP!" echo SVBgIGJlbG93KS4KCj4gKipPbmUtY2xpY2sgaW5zdGFsbC4qKiBUaGUgdmVyeSBmaXJzdCBxdWVz
  >> "!B64TMP!" echo dGlvbiBpcyB0aGUgc2V0dXAgdHlwZS4gQ2hvaWNlCj4gKioxKiogKHRoZSBFbnRlciBkZWZhdWx0
  >> "!B64TMP!" echo KSBza2lwcyBldmVyeSBxdWVzdGlvbiBhbmQgaW5zdGFsbHMgd2l0aCB0aGUgZGVmYXVsdHMKPiBz
  >> "!B64TMP!" echo aG93biBhYm92ZTsgY2hvaWNlICoqMioqIGFza3Mgb25seSB0aGUgdGhyZWUgTExNIHF1ZXN0aW9u
  >> "!B64TMP!" echo czsgY2hvaWNlCj4gKiozKiogZ29lcyB0aHJvdWdoIGFsbCBzaXggbnVtYmVyZWQgc3RlcHMgYmVs
  >> "!B64TMP!" echo b3cgc28geW91IGNhbiBjdXN0b21pemUKPiBhbnl0aGluZy4gRWl0aGVyIHdheSB5b3UgY2FuIHN0
  >> "!B64TMP!" echo aWxsIGNoYW5nZSB5b3VyIG1pbmQgYWZ0ZXJ3YXJkIGJ5IGVkaXRpbmcKPiBgLmVudmAgYW5kIHJ1
  >> "!B64TMP!" echo bm5pbmcgYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYC4KCj4gKipUaGUgb3B0aW9uYWwgTExN
  >> "!B64TMP!" echo IChTdGVwIDUsIG9yIHNldHVwIDIpLioqIEFueSBPcGVuQUktY29tcGF0aWJsZSBlbmRwb2ludAo+
  >> "!B64TMP!" echo IHdvcmtzLCBsb2NhbCBvciByZW1vdGU6IHRoZSBpbnN0YWxsZXIgYXNrcyBmb3IgaXRzIGJhc2Ug
  >> "!B64TMP!" echo VVJMIChkZWZhdWx0Cj4gYGh0dHA6Ly9sb2NhbGhvc3Q6MTIzNC92MWAsIExNIFN0dWRpbyksIGFu
  >> "!B64TMP!" echo IEFQSSBrZXkgKEVudGVyIHRvIHNraXApIGFuZCBhCj4gbW9kZWwgbmFtZSAoRW50ZXIgdG8gc2tp
  >> "!B64TMP!" echo cCksIGFuZCB3cml0ZXMgdGhlbSB0byBgLmVudmAuIFRoZSBleHRyYWN0aW9uIHRvb2wKPiBgd2Vi
  >> "!B64TMP!" echo X2V4dHJhY3QucHlgIGFuZCB0aGUgc2tpbGwncyAiTExNIGV4dHJhY3Rpb24iIHNlY3Rpb24gYXJl
  >> "!B64TMP!" echo IGluc3RhbGxlZAo+ICoqb25seSoqIHdoZW4gYW4gTExNIGlzIGNvbm5lY3RlZDsgd2l0aG91dCBv
  >> "!B64TMP!" echo bmUgdGhlIGluc3RhbGxlZCBza2lsbCBkb2VzIG5vdAo+IG1lbnRpb24gdGhlbS4gU2VlIFtzZWN0
  >> "!B64TMP!" echo aW9uIERdKCNkLWNvbm5lY3QtYW4tbGxtLWxtLXN0dWRpby1ldGMpLgoKPiAqKlRoZSBicm93c2Vy
  >> "!B64TMP!" echo IHJlbmRlcmluZyBlbmdpbmUgKFN0ZXAgNCkuKiogRmlyZWNyYXdsIG5lZWRzIGEgaGVhZGxlc3MK
  >> "!B64TMP!" echo PiBicm93c2VyIHRvIGZldGNoIEpTLXJlbmRlcmVkIHBhZ2VzLiBUaGUgZGVmYXVsdCBhbnN3ZXIs
  >> "!B64TMP!" echo ICoqTioqLCBrZWVwcwo+ICoqUGxheXdyaWdodCoqIOKAlCB0aGUgY2xhc3NpYyBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo ZW5naW5lIChgZ2hjci5pby9maXJlY3Jhd2wvcGxheXdyaWdodC1zZXJ2aWNlYCkuCj4gQW5zd2Vy
  >> "!B64TMP!" echo aW5nICoqeSoqIHN3aXRjaGVzIHRvICoqQnJvd3Nlcmxlc3MqKiAoYGdoY3IuaW8vYnJvd3Nlcmxl
  >> "!B64TMP!" echo c3MvY2hyb21pdW1gKQo+IGluc3RlYWQsIHJ1biBpbiBpdHMgYnVpbHQtaW4gc3RlYWx0aCBtb2Rl
  >> "!B64TMP!" echo LCB3aGljaCBtYXNrcyBjb21tb24gYXV0b21hdGlvbgo+IGZpbmdlcnByaW50cyAoZS5nLiBgbmF2
  >> "!B64TMP!" echo aWdhdG9yLndlYmRyaXZlcmApIGFuZCB0ZW5kcyB0byBnZXQgYmxvY2tlZCBsZXNzCj4gb2Z0ZW4g
  >> "!B64TMP!" echo YnkgQ2xvdWRmbGFyZS1zdHlsZSBib3QgY2hlY2tzLiBPbmx5IHRoZSBlbmdpbmUgeW91IHBpY2sg
  >> "!B64TMP!" echo aXMgYWN0dWFsbHkKPiBzdGFydGVkIOKAlCB0aGUgaW5zdGFsbGVyIHdyaXRlcyBgQ09NUE9TRV9Q
  >> "!B64TMP!" echo Uk9GSUxFU2AgYW5kCj4gYFBMQVlXUklHSFRfTUlDUk9TRVJWSUNFX1VSTGAgdG8gYC5lbnZgIGFj
  >> "!B64TMP!" echo Y29yZGluZ2x5LiBUbyBzd2l0Y2ggbGF0ZXIsIGVkaXQKPiB0aG9zZSB0d28gbGluZXMgaW4gYC5l
  >> "!B64TMP!" echo bnZgIGFuZCBydW4gYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYC4KCj4gKipUaGUgb3B0aW9u
  >> "!B64TMP!" echo YWwgRmlyZWNyYXdsIGFjY291bnQgKFN0ZXAgNikuKiogQSBmZXcgb2YgdGhlIGJ1bmRsZWQgc2tp
  >> "!B64TMP!" echo bGwncwo+IHRvb2xzIOKAlCB0aGUgcmVzZWFyY2ggYWdlbnQsIGxpdmUtcGFnZSBgaW50ZXJhY3Rg
  >> "!B64TMP!" echo LCBmaWxlIGBwYXJzZWAsIG1vbml0b3JzLAo+IHBhcGVyIHJlc2VhcmNoLCBhbmQgR2l0SHViL2Rl
  >> "!B64TMP!" echo dmVsb3BlciBzZWFyY2gg4oCUIG9ubHkgd29yayBhZ2FpbnN0IEZpcmVjcmF3bCdzCj4gcGFpZCBj
  >> "!B64TMP!" echo bG91ZCBBUEkuIFRoZSBkZWZhdWx0IGFuc3dlciBpcyAqKk4qKjogdGhvc2UgdG9vbHMgYXJlIHNp
  >> "!B64TMP!" echo bXBseSAqbm90Cj4gaW5zdGFsbGVkKiwgYW5kIHRoZSBza2lsbCBzaGlwcyBhIGxlYW5lciBgU0tJ
  >> "!B64TMP!" echo TEwubWRgIGNvdmVyaW5nIGp1c3QgdGhlIGZyZWUKPiBsb2NhbCB0b29scy4gQW5zd2VyICoqeSoq
  >> "!B64TMP!" echo IGluc3RlYWQgYW5kIHRoZSBpbnN0YWxsZXIgYXNrcyBmb3IgeW91ciBBUEkga2V5Cj4gKGFuZCBB
  >> "!B64TMP!" echo UEkgVVJMLCBkZWZhdWx0IGBodHRwczovL2FwaS5maXJlY3Jhd2wuZGV2YCksIHN0b3JlcyB0aGVt
  >> "!B64TMP!" echo IGluIHlvdXIKPiBgLmVudmAsIGFuZCBpbnN0YWxscyBhbGwgMjUgdG9vbHMgKDI2IHdpdGggTExN
  >> "!B64TMP!" echo IGV4dHJhY3Rpb24pLiBZb3UgY2FuIGNoYW5nZSB5b3VyIG1pbmQgbGF0ZXIKPiBieSByZS1ydW5u
  >> "!B64TMP!" echo aW5nIHRoZSBpbnN0YWxsZXIgYW5kIGFuc3dlcmluZyBkaWZmZXJlbnRseS4KCj4gKipGaXJzdCBy
  >> "!B64TMP!" echo dW4gZG93bmxvYWRzIH4z4oCTNCBHQiBvZiBEb2NrZXIgaW1hZ2VzKiogKFBsYXl3cmlnaHQncyBh
  >> "!B64TMP!" echo bmQgQnJvd3Nlcmxlc3Mncwo+IGltYWdlcyBlYWNoIGJ1bmRsZSBhIGZ1bGwgQ2hyb21pdW0sIHNv
  >> "!B64TMP!" echo IG9ubHkgdGhlIG9uZSB5b3UgcGlja2VkIGlzIHB1bGxlZCkuCj4gU3Vic2VxdWVudCBzdGFydHMg
  >> "!B64TMP!" echo YXJlIGEgZmV3IHNlY29uZHMuCgpXaGVuIGl0IGZpbmlzaGVzIHlvdSdsbCBzZWU6CgpgYGAKU2Vh
  >> "!B64TMP!" echo clhORyAgKHNlYXJjaCArIEpTT04gQVBJKTogIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MApGaXJlY3Jh
  >> "!B64TMP!" echo d2wgKHNjcmFwZS9jcmF3bCBBUEkpOiBodHRwOi8vbG9jYWxob3N0Ojk5OTEKQWdlbnQgc2tpbGw6
  >> "!B64TMP!" echo IEM6XFVzZXJzXFlvdVwuYWdlbnRzXHNraWxsc1xsb2NhbC13ZWItc2VhcmNoICAgKG9yIH4vLmFn
  >> "!B64TMP!" echo ZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaCkKYGBgCgpPcGVuIGBodHRwOi8vbG9jYWxob3N0
  >> "!B64TMP!" echo Ojk5OTBgIGluIGEgYnJvd3NlciB0byBzZWUgdGhlIFNlYXJYTkcgc2VhcmNoIFVJIOKAlCBvciwK
  >> "!B64TMP!" echo aWYgeW91ciBhZ2VudCBsb2FkcyBza2lsbHMgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9gLCBqdXN0
  >> "!B64TMP!" echo IGFzayBpdCB0byByZXNlYXJjaApzb21ldGhpbmcgY3VycmVudCBhbmQgaXQgd2lsbCB1c2UgKips
  >> "!B64TMP!" echo b2NhbC13ZWItc2VhcmNoKiogYXV0b21hdGljYWxseSAoc2VlCltzZWN0aW9uIEFdKCNhLXRoZS1i
  >> "!B64TMP!" echo dW5kbGVkLWxvY2FsLXdlYi1zZWFyY2gtc2tpbGwtcmVjb21tZW5kZWQpKS4KCi0tLQoKIyMgTWFu
  >> "!B64TMP!" echo YWdpbmcgdGhlIHN0YWNrCgpBZnRlciBpbnN0YWxsLCB0aGUgbWFuYWdlbWVudCBzY3JpcHRzIGxp
  >> "!B64TMP!" echo dmUgKippbiB5b3VyIGluc3RhbGwgZm9sZGVyKioKKGBDOlxVc2Vyc1xZb3VcbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo YCBvbiBXaW5kb3dzLCBgfi9sb2NhbC1zZWFyY2hgIG9uIExpbnV4L21hY09TKS4KVGhleSBhdXRv
  >> "!B64TMP!" echo LWRldGVjdCB0aGVpciBvd24gbG9jYXRpb24sIHNvIHlvdSBjYW4gcnVuIHRoZW0gZnJvbSBhbnl3
  >> "!B64TMP!" echo aGVyZSBieQpkb3VibGUtY2xpY2tpbmcgb3IgYC4vYC1pbmcgdGhlbS4KCnwgQWN0aW9uIHwgV2lu
  >> "!B64TMP!" echo ZG93cyB8IExpbnV4IC8gbWFjT1MgfAp8LS0tLS0tLS18LS0tLS0tLS0tfC0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LXwKfCAqKlN0YXJ0KiogdGhlIHN0YWNrIHwgYFJ1bi5iYXRgIHwgYC4vcnVuLnNoYCB8CnwgKipT
  >> "!B64TMP!" echo dG9wKiogKGtlZXAgZGF0YSkgfCBgU3RvcC5iYXRgIHwgYC4vc3RvcC5zaGAgfAp8ICoqVXBkYXRl
  >> "!B64TMP!" echo KiogaW1hZ2VzICsgYXBwbHkgYC5lbnZgIGNoYW5nZXMgKyAqKnJlLXN5bmMgdGhlIHNraWxsKiog
  >> "!B64TMP!" echo fCBgVXBkYXRlLmJhdGAgfCBgLi91cGRhdGUuc2hgIHwKfCAqKlVuaW5zdGFsbCoqIChjb250YWlu
  >> "!B64TMP!" echo ZXJzICsgdm9sdW1lcyArIHNraWxsLCBvcHRpb25hbCBmb2xkZXIgZGVsZXRlKSB8IGBVbmluc3Rh
  >> "!B64TMP!" echo bGwuYmF0YCB8IGAuL3VuaW5zdGFsbC5zaGAgfAoKLSAqKlN0b3AqKiBvbmx5IHJlbW92ZXMgY29u
  >> "!B64TMP!" echo dGFpbmVyczsgeW91ciBkYXRhIHZvbHVtZXMgKEZpcmVjcmF3bCBqb2Igc3RhdGUsCiAgcmVkaXMg
  >> "!B64TMP!" echo Y2FjaGUsIHJhYmJpdG1xL3Bvc3RncmVzIGRhdGEpIGFyZSBwcmVzZXJ2ZWQuCi0gKipVcGRhdGUq
  >> "!B64TMP!" echo KiBydW5zIGBkb2NrZXIgY29tcG9zZSBwdWxsYCB0aGVuIGBkb2NrZXIgY29tcG9zZSB1cCAtZGAg
  >> "!B64TMP!" echo KGBwb2RtYW4gY29tcG9zZSDigKZgIG9uIFBvZG1hbiksIHNvIGl0CiAgYm90aCB1cGdyYWRlcyBp
  >> "!B64TMP!" echo bWFnZXMgKiphbmQqKiBhcHBsaWVzIGFueSBwb3J0L0xMTSBlZGl0cyB5b3UgbWFkZSB0byBgLmVu
  >> "!B64TMP!" echo dmA7CiAgaXQgYWxzbyByZS1jb3BpZXMgdGhlIGJ1bmRsZWQgYGxvY2FsLXdlYi1zZWFyY2hgIHNr
  >> "!B64TMP!" echo aWxsIGludG8gYH4vLmFnZW50cy9za2lsbHMvYC4KLSAqKlVuaW5zdGFsbCoqIHJ1bnMgYGRvY2tl
  >> "!B64TMP!" echo ciBjb21wb3NlIGRvd24gLXZgIChkZWxldGVzIHZvbHVtZXMgKyBkYXRhKSwKICByZW1vdmVzIHRo
  >> "!B64TMP!" echo ZSBgbG9jYWwtd2ViLXNlYXJjaGAgc2tpbGwgZnJvbSBgfi8uYWdlbnRzL3NraWxscy9sb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoYCwgdGhlbgogIG9wdGlvbmFsbHkgZGVsZXRlcyB0aGUgaW5zdGFsbCBmb2xkZXIu
  >> "!B64TMP!" echo IFB1bGxlZCBpbWFnZXMgYXJlIGtlcHQ7IHJlY2xhaW0gdGhlbQogIHdpdGggYGRvY2tlciBpbWFn
  >> "!B64TMP!" echo ZSBwcnVuZSAtYWAgaWYgZGVzaXJlZC4KCi0tLQoKIyMgSG93IGl0IGZpdHMgdG9nZXRoZXIKCmBg
  >> "!B64TMP!" echo YAogICAgICAgIHlvdXIgQUkgbW9kZWwgLyBhZ2VudCAobG9jYWwtd2ViLXNlYXJjaCBza2lsbCkg
  >> "!B64TMP!" echo LyBNQ1AgY2xpZW50IC8gY2hhdCBVSQogICAgICAgICAgICAgICAgICAgICAg4pSCCiAgIOKUjOKU
  >> "!B64TMP!" echo gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUvOKU
  >> "!B64TMP!" echo gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
  >> "!B64TMP!" echo gOKUgOKUkAogICDilrwgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilrwK
  >> "!B64TMP!" echo aHR0cDovL2xvY2FsaG9zdDo5OTkwICAgICAgICAgICAgaHR0cDovL2xvY2FsaG9zdDo5OTkxCiAg
  >> "!B64TMP!" echo IOKUgiBTZWFyWE5HICAgICAgICAgICAgICAgICAgICAgICAgICAgIOKUgiBGaXJlY3Jhd2wgQVBJ
  >> "!B64TMP!" echo CiAgIOKUgiAgLSAvc2VhcmNoP3E9Li4uJmZvcm1hdD1qc29uICAgICAgIOKUgiAgLSAvdjEvc2Ny
  >> "!B64TMP!" echo YXBlICAgKG9uZSBVUkwgLT4gbWFya2Rvd24pCiAgIOKUgiAgLSBhZ2dyZWdhdGVzIH43MCBlbmdp
  >> "!B64TMP!" echo bmVzICAgICAgICAgICDilIIgIC0gL3YxL2NyYXdsICAgICh3aG9sZSBzaXRlLCBhc3luYykKICAg
  >> "!B64TMP!" echo 4pSCICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOKUgiAgLSAvdjEvbWFwICAg
  >> "!B64TMP!" echo ICAgKHNpdGUgVVJMIHRyZWUpCiAgIOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICDilIIgIC0gL3YxL3NlYXJjaCAgICgtPiB1c2VzIFNlYXJYTkchKQogICDilIIgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg4pSCICAtIC92MS9leHRyYWN0ICAoLT4gdXNl
  >> "!B64TMP!" echo cyB5b3VyIExMTSkKICAg4pSC4peE4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAIHdpcmVk
  >> "!B64TMP!" echo IHRvZ2V0aGVyIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUpCAgU0VBUlhOR19FTkRQ
  >> "!B64TMP!" echo T0lOVD1odHRwOi8vc2VhcnhuZzo4MDgwCiAgIOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICDilIIKICAg4pSU4pSA4pSA4pSA4pSA4pSA4pSA4pSAIHByaXZhdGUgZG9ja2Vy
  >> "!B64TMP!" echo IG5ldHdvcmsg4pSA4pSA4pSA4pSA4pSA4pSA4pSYCiAgICAgICAgICAgICAgICAgbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoLW5ldAogICBhbHNvIG9uIGl0OiBwbGF5d3JpZ2h0LXNlcnZpY2UgT1IgYnJvd3Nlcmxlc3Mg
  >> "!B64TMP!" echo KHdoaWNoZXZlciB5b3UgcGlja2VkIGluIFN0ZXAgNCksIHJlZGlzLCByYWJiaXRtcSwgbnVxLXBv
  >> "!B64TMP!" echo c3RncmVzCmBgYAoKRm91ciBrZXkgd2lyaW5nIGRlY2lzaW9ucyB0aGUgaW5zdGFsbGVyIG1ha2Vz
  >> "!B64TMP!" echo IGZvciB5b3U6CgoxLiAqKlNlYXJYTkcgSlNPTiArIG5vIGxpbWl0ZXIqKiDigJQgYGNvbmZpZy9z
  >> "!B64TMP!" echo ZWFyeG5nL3NldHRpbmdzLnltbGAgc2V0cwogICBgc2VhcmNoLmZvcm1hdHM6IFtodG1sLCBqc29u
  >> "!B64TMP!" echo XWAgYW5kIGBzZXJ2ZXIubGltaXRlcjogZmFsc2VgLCBzbyBtb2RlbHMgY2FuIGhpdAogICBgL3Nl
  >> "!B64TMP!" echo YXJjaD9mb3JtYXQ9anNvbmAgd2l0aG91dCBiZWluZyBibG9ja2VkIGFzIGEgYm90LgoyLiAqKkZp
  >> "!B64TMP!" echo cmVjcmF3bCDihpIgU2VhclhORyoqIOKAlCB0aGUgRmlyZWNyYXdsIGNvbnRhaW5lciBzZXRzCiAg
  >> "!B64TMP!" echo IGBTRUFSWE5HX0VORFBPSU5UPWh0dHA6Ly9zZWFyeG5nOjgwODBgLCBzbyBGaXJlY3Jhd2wncyBg
  >> "!B64TMP!" echo L3YxL3NlYXJjaGAgdXNlcyB5b3VyCiAgIGxvY2FsIFNlYXJYTkcgaW5zdGVhZCBvZiBuZWVkaW5n
  >> "!B64TMP!" echo IGEgdGhpcmQtcGFydHkgc2VhcmNoIHByb3ZpZGVyLgozLiAqKkZpcmVjcmF3bCDihpIgYnJvd3Nl
  >> "!B64TMP!" echo ciBlbmdpbmUqKiDigJQgYGRvY2tlci1jb21wb3NlLnltbGAgZGVmaW5lcyBib3RoCiAgIGBwbGF5
  >> "!B64TMP!" echo d3JpZ2h0LXNlcnZpY2VgIGFuZCBgYnJvd3Nlcmxlc3NgIGJlaGluZCBDb21wb3NlIHByb2ZpbGVz
  >> "!B64TMP!" echo OyBgLmVudmAncwogICBgQ09NUE9TRV9QUk9GSUxFU2AgKHNldCBieSBTdGVwIDQpIGVuYWJsZXMg
  >> "!B64TMP!" echo anVzdCBvbmUsIGFuZAogICBgUExBWVdSSUdIVF9NSUNST1NFUlZJQ0VfVVJMYCBwb2ludHMgRmly
  >> "!B64TMP!" echo ZWNyYXdsIGF0IGl0Lgo0LiAqKmxvY2FsLXdlYi1zZWFyY2ggc2tpbGwgYXV0by1pbnN0YWxsKiog
  >> "!B64TMP!" echo 4oCUIHRoZSBpbnN0YWxsZXIgY29waWVzIHRoZSBidW5kbGVkIHNraWxsIHRvCiAgIGB+Ly5hZ2Vu
  >> "!B64TMP!" echo dHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvYCAoYWRkL292ZXJyaWRlKSBhbmQgcmVjb3JkcyB0
  >> "!B64TMP!" echo aGUgaW5zdGFsbCBwYXRoIGluCiAgIGFuIGBpbnN0YWxsLWRpci50eHRgIGhpbnQgaW5zaWRlIHRo
  >> "!B64TMP!" echo ZSBza2lsbCwgc28gdGhlIHNraWxsIGZpbmRzIHRoZSBzdGFjayBldmVuCiAgIGlmIHlvdSBpbnN0
  >> "!B64TMP!" echo YWxsZWQgdG8gYSBjdXN0b20gZm9sZGVyIGFuZCBEb2NrZXIgaXNuJ3QgcnVubmluZyB5ZXQuIFdp
  >> "!B64TMP!" echo dGhvdXQgYQogICBjb25maWd1cmVkIEZpcmVjcmF3bCBhY2NvdW50IGl0IGluc3RhbGxzIG9ubHkg
  >> "!B64TMP!" echo dGhlIGZyZWUgbG9jYWwgdG9vbHMgYW5kIGEKICAgbWF0Y2hpbmcgY29yZS1vbmx5IGBTS0lMTC5t
  >> "!B64TMP!" echo ZGAuCgotLS0KCiMjIFVzaW5nIGl0IHdpdGggQUkgbW9kZWxzCgpUaGVyZSBhcmUgKipzZXZlbioq
  >> "!B64TMP!" echo IHdheXMgdG8gdXNlIHRoaXMgc3lzdGVtLCBmcm9tIGxvd2VzdCB0byBoaWdoZXN0CmludGVncmF0
  >> "!B64TMP!" echo aW9uLiBQaWNrIHdoYXQgZml0cyB5b3VyIHN0YWNrIOKAlCB5b3UgY2FuIG1peCBhbmQgbWF0Y2gu
  >> "!B64TMP!" echo CgojIyMgQS4gVGhlIGJ1bmRsZWQgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCAocmVjb21tZW5kZWQp
  >> "!B64TMP!" echo CgpUaGUgaW5zdGFsbGVyIHNoaXBzIHdpdGggKipsb2NhbC13ZWItc2VhcmNoKiosIGFuIGFnZW50
  >> "!B64TMP!" echo IHNraWxsIHRoYXQgdHVybnMgYW55CnNraWxsLWxvYWRpbmcgYWdlbnQgaW50byBhIHdlYiByZXNl
  >> "!B64TMP!" echo YXJjaGVyIHdpdGggemVybyBjb25maWd1cmF0aW9uLiBJZiB5b3VyCmFnZW50IHJlYWRzIHNraWxs
  >> "!B64TMP!" echo cyBmcm9tIGB+Ly5hZ2VudHMvc2tpbGxzL2AKKGBDOlxVc2Vyc1xZb3VcLmFnZW50c1xza2lsbHNc
  >> "!B64TMP!" echo YCBvbiBXaW5kb3dzKSwgaXQncyBhbHJlYWR5IGF2YWlsYWJsZSBhZnRlcgppbnN0YWxsIOKAlCBy
  >> "!B64TMP!" echo ZXN0YXJ0IHRoZSBhZ2VudCBpZiBpdCB3YXMgcnVubmluZy4KClRoZSBpbnN0YWxsZXI6Ci0gcHV0
  >> "!B64TMP!" echo cyBhIGNvcHkgaW4gYDxpbnN0YWxsIGZvbGRlcj4vbG9jYWwtd2ViLXNlYXJjaC9gLCBhbmQKLSAq
  >> "!B64TMP!" echo KmF1dG9tYXRpY2FsbHkgaW5zdGFsbHMgKGFkZC9vdmVycmlkZSkqKiBpdCBpbnRvCiAgYH4vLmFn
  >> "!B64TMP!" echo ZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaC9gLgoKV2hhdCB0aGUgc2tpbGwgZG9lcyBmb3Ig
  >> "!B64TMP!" echo dGhlIGFnZW50OgoKLSAqKkZpbmRzIHRoZSBzdGFjayBhdXRvbWF0aWNhbGx5LioqIEl0IHJlYWRz
  >> "!B64TMP!" echo IHRoZSByZWFsIHBvcnRzIGZyb20geW91ciBgLmVudmAKICAoc28gY3VzdG9tIGluc3RhbGwtdGlt
  >> "!B64TMP!" echo ZSBwb3J0cyBqdXN0IHdvcmspIGFuZCBsb2NhdGVzIHRoZSBpbnN0YWxsIGZvbGRlciB2aWEKICB0
  >> "!B64TMP!" echo aGUgY29tcG9zZSBsYWJlbHMgb24gdGhlIHJ1bm5pbmcgY29udGFpbmVycywgdGhlIGluc3RhbGxl
  >> "!B64TMP!" echo ci1yZWNvcmRlZAogIGBpbnN0YWxsLWRpci50eHRgIGhpbnQsIG9yIGB+L2xvY2FsLXNlYXJjaGAg
  >> "!B64TMP!" echo 4oCUIG5vIGhhcmRjb2RlZCBhbnl0aGluZy4KLSAqKlNlbGYtaGVhbHMgYSBkb3duIHN0YWNrIOKA
  >> "!B64TMP!" echo lCBubyB3YXJtLXVwIHN0ZXAuKiogSWYgdGhlIERvY2tlciBlbmdpbmUgb3IgdGhlCiAgY29udGFp
  >> "!B64TMP!" echo bmVycyBhcmUgZG93biB3aGVuIGEgc2VhcmNoL3NjcmFwZSBydW5zLCB0aGUgc2NyaXB0IGJvb3Rz
  >> "!B64TMP!" echo IHRoZSBlbmdpbmUKICAoRG9ja2VyIERlc2t0b3AgLyBgc3lzdGVtY3RsIHN0YXJ0IGRvY2tlcmAp
  >> "!B64TMP!" echo LCBydW5zIHRoZSBzYW1lIGBkb2NrZXIgY29tcG9zZQogIHVwIC1kYCB0aGF0IGBSdW4uYmF0YCAv
  >> "!B64TMP!" echo IGBydW4uc2hgIHVzZSwgd2FpdHMgZm9yIHRoZSBlbmRwb2ludHMsIGFuZCByZXRyaWVzCiAgdGhl
  >> "!B64TMP!" echo IHJlcXVlc3Qg4oCUIHNvIHRoZSBhZ2VudCBjYWxscyB0aGUgc2VhcmNoL3NjcmFwZSBzY3JpcHRz
  >> "!B64TMP!" echo IGRpcmVjdGx5LCBldmVuCiAgaW4gYW4gb2xkIGNvbnZlcnNhdGlvbiB3aGVyZSB0aGUgc3RhY2sg
  >> "!B64TMP!" echo aGFzIHNpbmNlIGdvbmUgZG93bgogIChgZW5zdXJlX3N0YWNrLnB5YCByZW1haW5zIGF2YWlsYWJs
  >> "!B64TMP!" echo ZSBhcyBhbiBvcHRpb25hbCBwcmUtZmxpZ2h0IGNoZWNrKS4gVGhlCiAgc3RhY2sgaXMgKipuZXZl
  >> "!B64TMP!" echo ciBzdG9wcGVkKiogYnkgdGhlIHNjcmlwdHMgKHN0b3BwaW5nIGlzIHlvdXIgam9iLCB2aWEKICBg
  >> "!B64TMP!" echo U3RvcC5iYXRgIC8gYHN0b3Auc2hgKS4KLSAqKlNlYXJjaGVzIHRoZSB3ZWIuKiogYHdlYl9zZWFy
  >> "!B64TMP!" echo Y2gucHkgInF1ZXJ5ImAgcHJpbnRzIHRoZSB0b3AgcmVzdWx0cyBhcwogIGB0aXRsZSAvIHVybCAv
  >> "!B64TMP!" echo IHNuaXBwZXRgLCB3aXRoIGAtLWxpbWl0YCwgYC0tdGltZS1yYW5nZSBkYXl8d2Vla3xtb250aGAs
  >> "!B64TMP!" echo IGFuZAogIGAtLWNhdGVnb3JpZXMgaXQsbmV3cyxnZW5lcmFsYCBvcHRpb25zLgotICoqUmVhZHMg
  >> "!B64TMP!" echo cGFnZXMuKiogYHdlYl9zY3JhcGUucHkgPHVybD5gIHJldHVybnMgdGhlIHBhZ2UgYXMgY2xlYW4g
  >> "!B64TMP!" echo TWFya2Rvd24KICAodHJ1bmNhdGVkIGF0IDIwLDAwMCBjaGFyczsgcmFpc2Ugd2l0aCBgLS1tYXgt
  >> "!B64TMP!" echo Y2hhcnNgKS4KLSAqKlJlYWRzIFlvdVR1YmUgdHJhbnNjcmlwdHMuKiogYHdlYl95b3V0dWJlX3Ry
  >> "!B64TMP!" echo YW5zY3JpcHQucHkgPHZpZGVvX2lkIHwgdXJsPiBbLS1sYW5nIGVuLGRlXWAKICBwcmludHMgYSB2
  >> "!B64TMP!" echo aWRlbydzIGNhcHRpb25zIGFzIGBbTU06U1NdIHRleHRgIGxpbmVzLiBJdCB0YWxrcyBkaXJlY3Rs
  >> "!B64TMP!" echo eSB0bwogIFlvdVR1YmUg4oCUIG5vIERvY2tlciBzdGFjaywgbm8gc2VsZi1oZWFsLCBubyBhY2Nv
  >> "!B64TMP!" echo dW50IG5lZWRlZCDigJQgdGhyb3VnaAogICoqeXQtZGxwKiogKGBwaXAgaW5zdGFsbCAtVSAieXQt
  >> "!B64TMP!" echo ZGxwW2RlZmF1bHRdImAsIHBsdXMgRGVubyBvciBOb2RlLmpzIDIyKyBvbgogIGBQQVRIYCkuIFlv
  >> "!B64TMP!" echo dVR1YmUgbm93IGd1YXJkcyB0aGUgY2FwdGlvbnMgb2YgYSBncm93aW5nIHNoYXJlIG9mIHZpZGVv
  >> "!B64TMP!" echo cyB3aXRoIGEKICAiUE8gdG9rZW4iIHRoYXQgcGxhaW4gc2NyYXBlcnMgc3VjaCBhcyBgeW91dHVi
  >> "!B64TMP!" echo ZS10cmFuc2NyaXB0LWFwaWAgY2Fubm90IHByb2R1Y2UKICAodGhleSBnZXQgYW4gZW1wdHkgYW5z
  >> "!B64TMP!" echo d2VyKTsgeXQtZGxwIGNhbi4gVGhlIG9sZGVyIHBhY2thZ2UgaXMga2VwdCBvbmx5IGFzIGEKICBm
  >> "!B64TMP!" echo YWxsYmFjayBmb3IgdmlkZW9zIHRoYXQgYXJlIG5vdCBiZWhpbmQgdGhlIHRva2VuIHlldC4KLSAq
  >> "!B64TMP!" echo KkV4cG9zZXMgdGhlIGZ1bGwgRmlyZWNyYXdsIE1DUCBzdXJmYWNlIOKAlCAyNCB0b29scy4qKiBC
  >> "!B64TMP!" echo ZXNpZGVzIHNlYXJjaCBhbmQKICBzY3JhcGUsIHRoZSBza2lsbCBzaGlwcyBzY3JpcHRzIG1pcnJv
  >> "!B64TMP!" echo cmluZyBldmVyeSBGaXJlY3Jhd2wgTUNQIHRvb2w6CiAgYHdlYl9tYXAucHlgIChlbnVtZXJhdGUg
  >> "!B64TMP!" echo YSBzaXRlJ3MgVVJMcyksIGB3ZWJfY3Jhd2wucHlgIC8KICBgd2ViX2NyYXdsX3N0YXR1cy5weWAg
  >> "!B64TMP!" echo KG11bHRpLXBhZ2UgY3Jhd2xzKSwgYHdlYl9hZ2VudC5weWAgLwogIGB3ZWJfYWdlbnRfc3RhdHVz
  >> "!B64TMP!" echo LnB5YCAoYXN5bmMgcmVzZWFyY2ggYWdlbnQpLCBgd2ViX2ludGVyYWN0LnB5YCAvCiAgYHdlYl9p
  >> "!B64TMP!" echo bnRlcmFjdF9zdG9wLnB5YCAobGl2ZSBicm93c2VyIHNlc3Npb25zKSwgYHdlYl9wYXJzZS5weWAg
  >> "!B64TMP!" echo KGxvY2FsCiAgUERGL1dvcmQvSFRNTC8uLi4gZG9jdW1lbnRzKSwgZWlnaHQgYHdlYl9tb25pdG9y
  >> "!B64TMP!" echo XyoucHlgIHNjcmlwdHMgKHJlY3VycmluZwogIGNoYW5nZSB0cmFja2luZyksIGZpdmUgYHdlYl9y
  >> "!B64TMP!" echo ZXNlYXJjaF8qLnB5YCBzY3JpcHRzIChiaW9tZWRpY2FsICsgYXJYaXYKICBwYXBlciBzZWFyY2gs
  >> "!B64TMP!" echo IGNpdGF0aW9uIGdyYXBoLCBmdWxsLXRleHQgcmVhZGluZyksIGB3ZWJfZ2l0aHViX3NlYXJjaC5w
  >> "!B64TMP!" echo eWAKICAoaW5kZXhlZCBHaXRIdWIgaXNzdWVzL1BScy9SRUFETUVzKSwgYW5kIGB3ZWJfZGV2ZWxv
  >> "!B64TMP!" echo cGVyX3NlYXJjaC5weWAgKGFuCiAgaW5kZXggYnVpbHQgZm9yIGNvZGluZyBhZ2VudHMpLiBFdmVy
  >> "!B64TMP!" echo eSBzY3JpcHQgc2VsZi1oZWFscyB0aGUgc3RhY2ssIHByaW50cwogIGNsZWFuIG91dHB1dCwgYW5k
  >> "!B64TMP!" echo IHN1cHBvcnRzIGAtLWpzb25gIGZvciB0aGUgcmF3IEFQSSByZXNwb25zZS4KLSAqKk9wdGlvbmFs
  >> "!B64TMP!" echo IGFjY291bnQgZmVhdHVyZXMuKiogVGhlIHJlc2VhcmNoIGFnZW50LCBpbnRlcmFjdCwgcGFyc2Us
  >> "!B64TMP!" echo CiAgbW9uaXRvcnMsIHBhcGVyIHJlc2VhcmNoLCBhbmQgZGV2ZWxvcGVyIHNlYXJjaCBhcmUgRmly
  >> "!B64TMP!" echo ZWNyYXdsIGFjY291bnQKICBmZWF0dXJlcyAocGFpZCBjbG91ZCBBUEkpLiBUaGUgaW5zdGFsbGVy
  >> "!B64TMP!" echo J3MgIkFkZCBhIEZpcmVjcmF3bCBhY2NvdW50PyIKICBxdWVzdGlvbiBkZWNpZGVzIGhvdyB0aGV5
  >> "!B64TMP!" echo J3JlIGhhbmRsZWQ6ICoqTioqIChkZWZhdWx0KSBza2lwcyB0aGVtIOKAlCB0aGUKICBza2lsbCBp
  >> "!B64TMP!" echo cyBpbnN0YWxsZWQgd2l0aCBvbmx5IHRoZSBmcmVlIGxvY2FsIHRvb2xzIChzZWFyY2gsIHNjcmFw
  >> "!B64TMP!" echo ZSwgbWFwLAogIGNyYXdsLCBjcmF3bCBzdGF0dXMsIFlvdVR1YmUgdHJhbnNjcmlwdHMpIGFuZCBh
  >> "!B64TMP!" echo IGNvcmUtb25seSBgU0tJTEwubWRgIHRoYXQKICBkb2Vzbid0IG1lbnRpb24gdGhlIGFjY291bnQg
  >> "!B64TMP!" echo dG9vbHM7ICoqeSoqIGluc3RhbGxzIGFsbCAyNSB0b29scyAoMjYgd2l0aCBMTE0gZXh0cmFjdGlv
  >> "!B64TMP!" echo bikgYW5kIHdyaXRlcwogIGBGSVJFQ1JBV0xfQVBJX1VSTGAgKyBgRklSRUNSQVdMX0FQSV9LRVlg
  >> "!B64TMP!" echo IGludG8geW91ciBgLmVudmAgc28gdGhvc2UKICBzY3JpcHRzIGNhbGwgdGhlIGNsb3VkIEFQSSBh
  >> "!B64TMP!" echo dXRvbWF0aWNhbGx5ICh0aGUgc2FtZSBlbnYgdmFyIG5hbWVzIHRoZQogIG9mZmljaWFsIGZpcmVj
  >> "!B64TMP!" echo cmF3bC1tY3Agc2VydmVyIHVzZXMsIGlmIHlvdSBwcmVmZXIgYGV4cG9ydGBpbmcgdGhlbSkuCgpN
  >> "!B64TMP!" echo YW51YWwgdXNhZ2UgKGV4YWN0bHkgd2hhdCB0aGUgYWdlbnQgcnVucyDigJQgbm8gc2VwYXJhdGUg
  >> "!B64TMP!" echo c3RhcnQgc3RlcCBuZWVkZWQpOgoKYGBgYmFzaApweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2Nh
  >> "!B64TMP!" echo bC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3NlYXJjaC5weSAibGF0ZXN0IHB5dGhvbiByZWxlYXNl
  >> "!B64TMP!" echo IgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3Nj
  >> "!B64TMP!" echo cmFwZS5weSAiaHR0cHM6Ly9leGFtcGxlLmNvbSIKIyBhIGZldyBvZiB0aGUgb3RoZXIgdG9vbHM6
  >> "!B64TMP!" echo CnB5dGhvbiB+Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy93ZWJfbWFw
  >> "!B64TMP!" echo LnB5ICJodHRwczovL2V4YW1wbGUuY29tIgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoL3NjcmlwdHMvd2ViX2NyYXdsLnB5ICJodHRwczovL2V4YW1wbGUuY29tIiAtLW1h
  >> "!B64TMP!" echo eC1wYWdlcyAxMApweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2NhbC13ZWItc2VhcmNoL3Njcmlw
  >> "!B64TMP!" echo dHMvd2ViX3BhcnNlLnB5ICJyZXBvcnQucGRmIgpweXRob24gfi8uYWdlbnRzL3NraWxscy9sb2Nh
  >> "!B64TMP!" echo bC13ZWItc2VhcmNoL3NjcmlwdHMvd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weSAiZFF3NHc5V2dY
  >> "!B64TMP!" echo Y1EiCiMgb3B0aW9uYWwgcHJlLWZsaWdodCBjaGVjayAvIHN0YXR1cyByZXBvcnQ6CnB5dGhvbiB+
  >> "!B64TMP!" echo Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gvc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkg
  >> "!B64TMP!" echo LS1jaGVjawpgYGAKClRoZSBmdWxsIGFnZW50LWZhY2luZyBpbnN0cnVjdGlvbnMgbGl2ZSBpbiB0
  >> "!B64TMP!" echo aGUgc2tpbGwncyBgU0tJTEwubWRgLiBLZWVwaW5nIHRoZQpza2lsbCBmcmVzaCBpcyBhdXRvbWF0
  >> "!B64TMP!" echo aWM6IGBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAgcmUtc3luY3MgaXQsIGFuZApyZS1ydW5u
  >> "!B64TMP!" echo aW5nIHRoZSBpbnN0YWxsZXIgb3ZlcndyaXRlcyBpdC4gVW5pbnN0YWxsaW5nIHJlbW92ZXMgaXQu
  >> "!B64TMP!" echo Cgo+IFRoZSBza2lsbCBvbmx5IG5lZWRzICoqUHl0aG9uIDMuOCsqKiBvbiB0aGUgaG9zdCDigJQg
  >> "!B64TMP!" echo bm8gQVBJIGtleXMsIG5vIE1DUAo+IHN1cHBvcnQgcmVxdWlyZWQgZnJvbSB0aGUgYWdlbnQuIEV2
  >> "!B64TMP!" echo ZXJ5IHRvb2wgaXMgc3RkbGliLW9ubHkgZXhjZXB0Cj4gYHdlYl95b3V0dWJlX3RyYW5zY3JpcHQu
  >> "!B64TMP!" echo cHlgLCB3aGljaCBuZWVkcyAqKnl0LWRscCoqCj4gKGBwaXAgaW5zdGFsbCAtVSAieXQtZGxwW2Rl
  >> "!B64TMP!" echo ZmF1bHRdImApIGFuZCBhIEphdmFTY3JpcHQgcnVudGltZSAoRGVubyBvciBOb2RlLmpzIDIyKyku
  >> "!B64TMP!" echo CgotLS0KCiMjIyBCLiBEaXJlY3QgU2VhclhORyBKU09OIEFQSQoKVGhlIHNpbXBsZXN0IHBvc3Np
  >> "!B64TMP!" echo YmxlIGludGVncmF0aW9uOiBoaXQgU2VhclhORydzIEpTT04gZW5kcG9pbnQgYW5kIGZlZWQgdGhl
  >> "!B64TMP!" echo CnJlc3VsdHMgaW50byBhbnkgbW9kZWwncyBjb250ZXh0LiBObyBTREssIG5vIGtleSwgbm8gTUNQ
  >> "!B64TMP!" echo LgoKYGBgYmFzaAojIFNlYXJjaCB0aGUgd2ViLCByZXR1cm4gSlNPTiwgc2hvdyB0aGUgdG9wIDUg
  >> "!B64TMP!" echo cmVzdWx0cwpjdXJsIC1zICJodHRwOi8vbG9jYWxob3N0Ojk5OTAvc2VhcmNoP3E9bGF0ZXN0K0FJ
  >> "!B64TMP!" echo K25ld3MmZm9ybWF0PWpzb24iIFwKICB8IGpxICcucmVzdWx0c1s6NV0gfCAuW10gfCB7dGl0bGUs
  >> "!B64TMP!" echo IHVybCwgY29udGVudH0nCmBgYAoKVXNlZnVsIHF1ZXJ5IHBhcmFtczogYCZwYWdlbm89MmAsIGAm
  >> "!B64TMP!" echo Y2F0ZWdvcmllcz1pdCxpbWFnZXNgLCBgJnRpbWVfcmFuZ2U9ZGF5YCwKYCZsYW5ndWFnZT1lbmAs
  >> "!B64TMP!" echo IGAmZW5naW5lcz1nb29nbGUsYmluZyxkdWNrZHVja2dvYC4KCkluIFB5dGhvbjoKCmBgYHB5dGhv
  >> "!B64TMP!" echo bgppbXBvcnQgcmVxdWVzdHMKciA9IHJlcXVlc3RzLmdldCgiaHR0cDovL2xvY2FsaG9zdDo5OTkw
  >> "!B64TMP!" echo L3NlYXJjaCIsIHBhcmFtcz17CiAgICAicSI6ICJydXN0IGFzeW5jIHJ1bnRpbWUgdG9raW8iLAog
  >> "!B64TMP!" echo ICAgImZvcm1hdCI6ICJqc29uIiwKICAgICJsYW5ndWFnZSI6ICJlbiIsCn0pLmpzb24oKQpmb3Ig
  >> "!B64TMP!" echo aGl0IGluIHJbInJlc3VsdHMiXVs6NV06CiAgICBwcmludChoaXRbInRpdGxlIl0sICItPiIsIGhp
  >> "!B64TMP!" echo dFsidXJsIl0pCiAgICBwcmludChoaXQuZ2V0KCJjb250ZW50IiwgIiIpWzoyMDBdKQpgYGAKCj4g
  >> "!B64TMP!" echo U2VhclhORyByZXR1cm5zIHRpdGxlcywgVVJMcywgYW5kIHNob3J0IGNvbnRlbnQgc25pcHBldHMg
  >> "!B64TMP!" echo 4oCUIHBlcmZlY3QgZm9yIGEKPiAic2VhcmNoIHRoZW4gc3VtbWFyaXplIiBhZ2VudCBsb29wLiBG
  >> "!B64TMP!" echo b3IgKipmdWxsIHBhZ2UgdGV4dCoqLCB1c2UgRmlyZWNyYXdsIChDKS4KCi0tLQoKIyMjIEMuIERp
  >> "!B64TMP!" echo cmVjdCBGaXJlY3Jhd2wgUkVTVCBBUEkKCkZpcmVjcmF3bCB0dXJucyBhbnkgVVJMIGludG8gY2xl
  >> "!B64TMP!" echo YW4gTWFya2Rvd24vSFRNTC9KU09OIOKAlCBpZGVhbCBmb3IgUkFHLiBCZWNhdXNlCnRoZSBzZWxm
  >> "!B64TMP!" echo LWhvc3RlZCBpbnN0YW5jZSBydW5zIHdpdGggYFVTRV9EQl9BVVRIRU5USUNBVElPTj1mYWxzZWAs
  >> "!B64TMP!" echo ICoqbm8gQVBJIGtleQppcyByZXF1aXJlZCoqICh5b3UgY2FuIHNlbmQgYW55IGBBdXRob3JpemF0
  >> "!B64TMP!" echo aW9uOiBCZWFyZXIg4oCmYCBoZWFkZXIsIG9yIG5vbmUpLgoKIyMjIyBTY3JhcGUgYSBzaW5nbGUg
  >> "!B64TMP!" echo cGFnZSDihpIgTWFya2Rvd24KCmBgYGJhc2gKY3VybCAtcyAtWCBQT1NUIGh0dHA6Ly9sb2NhbGhv
  >> "!B64TMP!" echo c3Q6OTk5MS92MS9zY3JhcGUgXAogIC1IICJDb250ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24i
  >> "!B64TMP!" echo IFwKICAtZCAneyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tIiwiZm9ybWF0cyI6WyJtYXJrZG93
  >> "!B64TMP!" echo biJdfScgXAogIHwganEgJy5kYXRhLm1hcmtkb3duJwpgYGAKCiMjIyMgU2VhcmNoIHRoZSB3ZWIg
  >> "!B64TMP!" echo KHVzZXMgeW91ciBTZWFyWE5HIGludGVybmFsbHkpICsgcmV0dXJuIGZ1bGwgY29udGVudAoKYGBg
  >> "!B64TMP!" echo YmFzaApjdXJsIC1zIC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL3NlYXJjaCBcCiAg
  >> "!B64TMP!" echo LUggIkNvbnRlbnQtVHlwZTogYXBwbGljYXRpb24vanNvbiIgXAogIC1kICd7InF1ZXJ5Ijoid2hh
  >> "!B64TMP!" echo dCBpcyBydXN0IHByb2dyYW1taW5nIGxhbmd1YWdlIiwibGltaXQiOjV9JyBcCiAgfCBqcSAnLmRh
  >> "!B64TMP!" echo dGFbOjNdIHwgLltdIHwge3RpdGxlLCB1cmwsIG1hcmtkb3dufScKYGBgCgojIyMjIENyYXdsIGEg
  >> "!B64TMP!" echo d2hvbGUgc2l0ZSAoYXN5bmMpCgpgYGBiYXNoCiMgMSkgc3RhcnQgdGhlIGNyYXdsCkpPQj0kKGN1
  >> "!B64TMP!" echo cmwgLXMgLVggUE9TVCBodHRwOi8vbG9jYWxob3N0Ojk5OTEvdjEvY3Jhd2wgXAogIC1IICJDb250
  >> "!B64TMP!" echo ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmwiOiJodHRwczovL2RvY3Mu
  >> "!B64TMP!" echo ZXhhbXBsZS5jb20iLCJsaW1pdCI6MjB9JyB8IGpxIC1yIC5pZCkKCiMgMikgcG9sbCB1bnRpbCBz
  >> "!B64TMP!" echo dGF0dXMgPT0gImNvbXBsZXRlZCIKY3VybCAtcyAiaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2Ny
  >> "!B64TMP!" echo YXdsLyRKT0IiIHwganEgJ3tzdGF0dXMsIGNvbXBsZXRlZCwgdG90YWx9JwpgYGAKCiMjIyMgTWFw
  >> "!B64TMP!" echo IGEgc2l0ZSdzIFVSTCB0cmVlIChmYXN0LCBubyBzY3JhcGluZykKCmBgYGJhc2gKY3VybCAtcyAt
  >> "!B64TMP!" echo WCBQT1NUIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9tYXAgXAogIC1IICJDb250ZW50LVR5cGU6
  >> "!B64TMP!" echo IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmwiOiJodHRwczovL2V4YW1wbGUuY29tIiwi
  >> "!B64TMP!" echo bGltaXQiOjUwfScgfCBqcSAnLmxpbmtzJwpgYGAKCiMjIyMgRXh0cmFjdCBzdHJ1Y3R1cmVkIGRh
  >> "!B64TMP!" echo dGEgd2l0aCBhbiBMTE0gKG5lZWRzIHNlY3Rpb24gRCBjb25maWd1cmVkKQoKYGBgYmFzaApjdXJs
  >> "!B64TMP!" echo IC1zIC1YIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL2V4dHJhY3QgXAogIC1IICJDb250
  >> "!B64TMP!" echo ZW50LVR5cGU6IGFwcGxpY2F0aW9uL2pzb24iIFwKICAtZCAneyJ1cmxzIjpbImh0dHBzOi8vZXhh
  >> "!B64TMP!" echo bXBsZS5jb20iXSwicHJvbXB0IjoiRXh0cmFjdCB0aGUgY29tcGFueSBuYW1lIGFuZCBhIGNvbnRh
  >> "!B64TMP!" echo Y3QgZW1haWwifScgXAogIHwganEgJy5kYXRhJwpgYGAKCiMjIyMgVXNpbmcgdGhlIEZpcmVjcmF3
  >> "!B64TMP!" echo bCBTREtzIChOb2RlIC8gUHl0aG9uKQoKU2VsZi1ob3N0IHdvcmtzIHdpdGggdGhlIG9mZmljaWFs
  >> "!B64TMP!" echo IFNES3Mg4oCUIHBvaW50IHRoZW0gYXQgeW91ciBsb2NhbCBVUkwgYW5kIHBhc3MKYW55IG5vbi1l
  >> "!B64TMP!" echo bXB0eSBzdHJpbmcgYXMgdGhlIGtleToKCioqTm9kZS5qcyoqCmBgYGpzCmltcG9ydCBGaXJlY3Jh
  >> "!B64TMP!" echo d2wgZnJvbSAiQG1lbmRhYmxlL2ZpcmVjcmF3bC1qcyI7Cgpjb25zdCBmYyA9IG5ldyBGaXJlY3Jh
  >> "!B64TMP!" echo d2woewogIGFwaUtleTogImZjLWxvY2FsIiwgICAgICAgICAgICAgIC8vIGFueSBub24tZW1wdHkg
  >> "!B64TMP!" echo c3RyaW5nOyBzZWxmLWhvc3QgZG9lc24ndCB2YWxpZGF0ZQogIGFwaVVybDogImh0dHA6Ly9sb2Nh
  >> "!B64TMP!" echo bGhvc3Q6OTk5MSIsIC8vIDwtLSBwb2ludCBhdCB5b3VyIGxvY2FsIGluc3RhbmNlCn0pOwoKY29u
  >> "!B64TMP!" echo c3QgeyBkYXRhIH0gPSBhd2FpdCBmYy5zY3JhcGVVcmwoImh0dHBzOi8vZXhhbXBsZS5jb20iLCB7
  >> "!B64TMP!" echo IGZvcm1hdHM6IFsibWFya2Rvd24iXSB9KTsKY29uc29sZS5sb2coZGF0YS5tYXJrZG93bik7CmBg
  >> "!B64TMP!" echo YAoKKipQeXRob24qKgpgYGBweXRob24KZnJvbSBmaXJlY3Jhd2wgaW1wb3J0IEZpcmVjcmF3bEFw
  >> "!B64TMP!" echo cAoKZmMgPSBGaXJlY3Jhd2xBcHAoYXBpX2tleT0iZmMtbG9jYWwiLCBhcGlfdXJsPSJodHRwOi8v
  >> "!B64TMP!" echo bG9jYWxob3N0Ojk5OTEiKQpyZXN1bHQgPSBmYy5zY3JhcGVfdXJsKCJodHRwczovL2V4YW1wbGUu
  >> "!B64TMP!" echo Y29tIiwgcGFyYW1zPXsiZm9ybWF0cyI6IFsibWFya2Rvd24iXX0pCnByaW50KHJlc3VsdFsibWFy
  >> "!B64TMP!" echo a2Rvd24iXSkKYGBgCgotLS0KCiMjIyBELiBDb25uZWN0IGFuIExMTSAoTE0gU3R1ZGlvLCBldGMu
  >> "!B64TMP!" echo KQoKQnkgZGVmYXVsdCwgRmlyZWNyYXdsJ3MgYC92MS9zY3JhcGVgLCBgL3YxL2NyYXdsYCwgYC92
  >> "!B64TMP!" echo MS9tYXBgLCBhbmQgYC92MS9zZWFyY2hgCndvcmsgKip3aXRob3V0IGFueSBMTE0qKi4gVG8gdW5s
  >> "!B64TMP!" echo b2NrICoqYC92MS9leHRyYWN0YCoqIChBSSBleHRyYWN0aW9uKSBhbmQgdGhlCmBzdW1tYXJ5YCBv
  >> "!B64TMP!" echo dXRwdXQgZm9ybWF0LCBwb2ludCBGaXJlY3Jhd2wgYXQgYW55ICoqT3BlbkFJLWNvbXBhdGlibGUq
  >> "!B64TMP!" echo KiBlbmRwb2ludC4KKipMTSBTdHVkaW8gaXMgdGhlIHJlY29tbWVuZGVkIGRlZmF1bHQqKiAocHJp
  >> "!B64TMP!" echo b3JpdHkgb3ZlciBPbGxhbWEpLgoKIyMjIyBSZWNvbW1lbmRlZDogTE0gU3R1ZGlvCgoxLiBJbnN0
  >> "!B64TMP!" echo YWxsIFtMTSBTdHVkaW9dKGh0dHBzOi8vbG1zdHVkaW8uYWkvKSwgZG93bmxvYWQgYSBtb2RlbCAo
  >> "!B64TMP!" echo ZS5nLiBgUXdlbjIuNS03Qi1JbnN0cnVjdGApLgoyLiBHbyB0byB0aGUgKipEZXZlbG9wZXIqKiB0
  >> "!B64TMP!" echo YWIg4oaSICoqU3RhcnQgU2VydmVyKiogb24gcG9ydCBgMTIzNGAgKGRlZmF1bHQpLgozLiAqKkVu
  >> "!B64TMP!" echo YWJsZSAiU2VydmUgb24gbG9jYWwgbmV0d29yayIqKiAocmVxdWlyZWQg4oCUIEZpcmVjcmF3bCBy
  >> "!B64TMP!" echo dW5zIGluIGEgY29udGFpbmVyCiAgIGFuZCByZWFjaGVzIHlvdXIgaG9zdCB2aWEgYGhvc3QuZG9j
  >> "!B64TMP!" echo a2VyLmludGVybmFsYCwgd2hpY2ggaXMgeW91ciBMQU4gSVAsIG5vdAogICBgMTI3LjAuMC4xYCku
  >> "!B64TMP!" echo CjQuIEVpdGhlcjoKICAgLSByZS1ydW4gdGhlIGluc3RhbGxlciAoc2V0dXAgKioyKiosIG9yICoq
  >> "!B64TMP!" echo MyoqIGFuZCBhbnN3ZXIgKip5KiogdG8gKiJDb25uZWN0CiAgICAgTExNIG5vdz8iKikg4oCUIGl0
  >> "!B64TMP!" echo IGF1dG8tY29udmVydHMgYGh0dHA6Ly9sb2NhbGhvc3Q6MTIzNC92MWAg4oaSCiAgICAgYGh0dHA6
  >> "!B64TMP!" echo Ly9ob3N0LmRvY2tlci5pbnRlcm5hbDoxMjM0L3YxYCBhbmQgd3JpdGVzIGl0IGludG8gYC5lbnZg
  >> "!B64TMP!" echo OyAqKm9yKioKICAgLSBlZGl0IGAuZW52YCBkaXJlY3RseSBhbmQgc2V0OgogICAgIGBgYGVudgog
  >> "!B64TMP!" echo ICAgIE9QRU5BSV9CQVNFX1VSTD1odHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6MTIzNC92MQog
  >> "!B64TMP!" echo ICAgIE9QRU5BSV9BUElfS0VZPWxtLXN0dWRpbwogICAgIE1PREVMX05BTUU9PHRoZSBtb2RlbCBp
  >> "!B64TMP!" echo ZCBsb2FkZWQgaW4gTE0gU3R1ZGlvPgogICAgIGBgYAo1LiBBcHBseSB3aXRoIGBVcGRhdGUuYmF0
  >> "!B64TMP!" echo YCAvIGAuL3VwZGF0ZS5zaGAuCgojIyMjIE90aGVyIE9wZW5BSS1jb21wYXRpYmxlIHNlcnZlcnMg
  >> "!B64TMP!" echo KHZMTE0sIGxsYW1hLmNwcCBgc2VydmVyYCwgdGV4dC1nZW5lcmF0aW9uLWluZmVyZW5jZSwgTG9j
  >> "!B64TMP!" echo YWxBSSwg4oCmKQoKYGBgZW52Ck9QRU5BSV9CQVNFX1VSTD1odHRwOi8vPGhvc3Qtb3ItaXA+Ojxw
  >> "!B64TMP!" echo b3J0Pi92MQpPUEVOQUlfQVBJX0tFWT1wbGFjZWhvbGRlciAgICAgICMgYW55IG5vbi1lbXB0eSBz
  >> "!B64TMP!" echo dHJpbmcgaWYgeW91ciBzZXJ2ZXIgaWdub3JlcyBpdApNT0RFTF9OQU1FPTxtb2RlbCBpZCBmcm9t
  >> "!B64TMP!" echo IEdFVCAvdjEvbW9kZWxzPgpgYGAKCkZvciBhIHJlbW90ZSBzZXJ2ZXIgb24gYW5vdGhlciBtYWNo
  >> "!B64TMP!" echo aW5lLCB1c2UgaXRzIElQIGRpcmVjdGx5IChlLmcuCmBodHRwOi8vMTkyLjE2OC4xLjUwOjgwMDAv
  >> "!B64TMP!" echo djFgKS4gRm9yIGEgc2VydmVyIG9uIHRoZSAqKnNhbWUgaG9zdCBhcyBEb2NrZXIqKiwgdXNlCmBo
  >> "!B64TMP!" echo dHRwOi8vaG9zdC5kb2NrZXIuaW50ZXJuYWw6PHBvcnQ+L3YxYC4KCiMjIyMgRmFsbGJhY2s6IE9s
  >> "!B64TMP!" echo bGFtYQoKSWYgeW91IHByZWZlciBPbGxhbWEsIHNldCAoRmlyZWNyYXdsIHJlYWRzIGBPTExBTUFf
  >> "!B64TMP!" echo QkFTRV9VUkxgKToKCmBgYGVudgpPTExBTUFfQkFTRV9VUkw9aHR0cDovL2hvc3QuZG9ja2VyLmlu
  >> "!B64TMP!" echo dGVybmFsOjExNDM0L2FwaQpNT0RFTF9OQU1FPXF3ZW4yLjU6N2IKTU9ERUxfRU1CRURESU5HX05B
  >> "!B64TMP!" echo TUU9bm9taWMtZW1iZWQtdGV4dApgYGAKClJlc3RhcnQgd2l0aCBgVXBkYXRlLmJhdGAgLyBgLi91
  >> "!B64TMP!" echo cGRhdGUuc2hgLCB0aGVuIGAvdjEvZXh0cmFjdGAgcm91dGVzIHRvIE9sbGFtYS4KCi0tLQoKIyMj
  >> "!B64TMP!" echo IEUuIFZpYSBhbiBNQ1Agc2VydmVyCgpUaGUgb2ZmaWNpYWwgWyoqRmlyZWNyYXdsIE1DUCBzZXJ2
  >> "!B64TMP!" echo ZXIqKl0oaHR0cHM6Ly9naXRodWIuY29tL2ZpcmVjcmF3bC9maXJlY3Jhd2wtbWNwLXNlcnZlcikK
  >> "!B64TMP!" echo ZXhwb3NlcyBgZmlyZWNyYXdsX3NlYXJjaGAsIGBmaXJlY3Jhd2xfc2NyYXBlYCwgYGZpcmVjcmF3
  >> "!B64TMP!" echo bF9jcmF3bGAsIGBmaXJlY3Jhd2xfbWFwYCwKYGZpcmVjcmF3bF9leHRyYWN0YCwgYW5kIHJlc2Vh
  >> "!B64TMP!" echo cmNoIHRvb2xzIHRvIGFueSBNQ1AtY29tcGF0aWJsZSBjbGllbnQuIFBvaW50IGl0IGF0CnlvdXIg
  >> "!B64TMP!" echo bG9jYWwgRmlyZWNyYXdsIHdpdGggYEZJUkVDUkFXTF9BUElfVVJMYC4KCiMjIyMgQ2xhdWRlIERl
  >> "!B64TMP!" echo c2t0b3AgKGBjbGF1ZGVfZGVza3RvcF9jb25maWcuanNvbmApCgpgYGBqc29uCnsKICAibWNwU2Vy
  >> "!B64TMP!" echo dmVycyI6IHsKICAgICJmaXJlY3Jhd2wiOiB7CiAgICAgICJjb21tYW5kIjogIm5weCIsCiAgICAg
  >> "!B64TMP!" echo ICJhcmdzIjogWyIteSIsICJmaXJlY3Jhd2wtbWNwIl0sCiAgICAgICJlbnYiOiB7CiAgICAgICAg
  >> "!B64TMP!" echo IkZJUkVDUkFXTF9BUElfVVJMIjogImh0dHA6Ly9sb2NhbGhvc3Q6OTk5MSIsCiAgICAgICAgIkZJ
  >> "!B64TMP!" echo UkVDUkFXTF9BUElfS0VZIjogImZjLWxvY2FsIgogICAgICB9CiAgICB9CiAgfQp9CmBgYAoKIyMj
  >> "!B64TMP!" echo IyBDdXJzb3IsIFZTIENvZGUsIFdpbmRzdXJmLCBDb250aW51ZSwgQ2xpbmUsIGV0Yy4KClNhbWUg
  >> "!B64TMP!" echo c2hhcGUg4oCUIGFkZCBhbiBgbWNwU2VydmVyc2AgZW50cnkgdG8gdGhhdCB0b29sJ3MgY29uZmln
  >> "!B64TMP!" echo IGZpbGUKKGB+Ly5jdXJzb3IvbWNwLmpzb25gLCBgLnZzY29kZS9tY3AuanNvbmAsIGAuL2NvZGVp
  >> "!B64TMP!" echo dW0vd2luZHN1cmYvbW9kZWxfY29uZmlnLmpzb25gLCDigKYpLgoKYGBganNvbgp7CiAgIm1jcFNl
  >> "!B64TMP!" echo cnZlcnMiOiB7CiAgICAiZmlyZWNyYXdsIjogewogICAgICAiY29tbWFuZCI6ICJucHgiLAogICAg
  >> "!B64TMP!" echo ICAiYXJncyI6IFsiLXkiLCAiZmlyZWNyYXdsLW1jcCJdLAogICAgICAiZW52IjogewogICAgICAg
  >> "!B64TMP!" echo ICJGSVJFQ1JBV0xfQVBJX1VSTCI6ICJodHRwOi8vbG9jYWxob3N0Ojk5OTEiLAogICAgICAgICJG
  >> "!B64TMP!" echo SVJFQ1JBV0xfQVBJX0tFWSI6ICJmYy1sb2NhbCIKICAgICAgfQogICAgfQogIH0KfQpgYGAKCj4g
  >> "!B64TMP!" echo VGhlIE1DUCBzZXJ2ZXIgcnVucyBvbiB5b3VyIGhvc3QgKG5vdCBpbiBEb2NrZXIpLCBzbyBpdCBy
  >> "!B64TMP!" echo ZWFjaGVzIEZpcmVjcmF3bCBhdAo+IGBodHRwOi8vbG9jYWxob3N0Ojk5OTFgLiAqKk5vIHJlYWwg
  >> "!B64TMP!" echo QVBJIGtleSBpcyBuZWVkZWQqKiDigJQgYGZjLWxvY2FsYCBpcyBhCj4gcGxhY2Vob2xkZXI7IHRo
  >> "!B64TMP!" echo ZSBzZWxmLWhvc3RlZCBGaXJlY3Jhd2wgZG9lc24ndCB2YWxpZGF0ZSBpdC4gUmVxdWlyZXMgTm9k
  >> "!B64TMP!" echo ZS5qcwo+IDE4KyBmb3IgYG5weGAuCgo+ICoqTm90ZSBmb3IgbG9jYWwgbGxhbWEuY3BwIHNlcnZl
  >> "!B64TMP!" echo cnM6KiogdGhlIEZpcmVjcmF3bCBNQ1Agc2VydmVyIHNoaXBzIHZlcnkKPiBsYXJnZSB0b29sIGRl
  >> "!B64TMP!" echo ZmluaXRpb25zLCB3aGljaCBjYW4gZXhjZWVkIHNvbWUgbG9jYWwgaW5mZXJlbmNlIHNlcnZlcnMn
  >> "!B64TMP!" echo Cj4gbGltaXRzIChlLmcuIGxsYW1hLmNwcCdzIGBNQVhfUkVQRVRJVElPTl9USFJFU0hPTERgIG9m
  >> "!B64TMP!" echo IDIwMDApLiBJZiB5b3VyIGxvY2FsCj4gbW9kZWwgZmFpbHMgdG8gbG9hZCB0aGUgTUNQIHRvb2xz
  >> "!B64TMP!" echo LCB1c2UgdGhlIGJ1bmRsZWQgKipsb2NhbC13ZWItc2VhcmNoIHNraWxsKioKPiAoW3NlY3Rpb24g
  >> "!B64TMP!" echo QV0oI2EtdGhlLWJ1bmRsZWQtbG9jYWwtd2ViLXNlYXJjaC1za2lsbC1yZWNvbW1lbmRlZCkpIGlu
  >> "!B64TMP!" echo c3RlYWQg4oCUIGl0IHdvcmtzCj4gd2l0aCBhbnkgbW9kZWwgdGhhdCBjYW4gcnVuIGEgc2hlbGwg
  >> "!B64TMP!" echo Y29tbWFuZCwgYW5kIGlzIHRoZSByZWNvbW1lbmRlZCBwYXRoIGZvcgo+IGxvY2FsIHNldHVwcyBh
  >> "!B64TMP!" echo bnl3YXkuCgojIyMjIFJ1biB0aGUgTUNQIHNlcnZlciBvdmVyIEhUVFAgKG9wdGlvbmFsKQoKYGBg
  >> "!B64TMP!" echo YmFzaApIVFRQX1NUUkVBTUFCTEVfU0VSVkVSPXRydWUgXApGSVJFQ1JBV0xfQVBJX1VSTD1odHRw
  >> "!B64TMP!" echo Oi8vbG9jYWxob3N0Ojk5OTEgXApGSVJFQ1JBV0xfQVBJX0tFWT1mYy1sb2NhbCBcCm5weCAteSBm
  >> "!B64TMP!" echo aXJlY3Jhd2wtbWNwCiMgLT4gaHR0cDovL2xvY2FsaG9zdDozMDAwL21jcApgYGAKCi0tLQoKIyMj
  >> "!B64TMP!" echo IEYuIFZpYSBwcm9tcHRpbmcgKGFueSBjaGF0IFVJKQoKTm8gTUNQLCBubyBTREssIG5vIGNvZGUg
  >> "!B64TMP!" echo 4oCUIGp1c3QgdGVsbCB0aGUgbW9kZWwgd2hlcmUgdGhlIHRvb2xzIGFyZS4gUGFzdGUgdGhpcwpz
  >> "!B64TMP!" echo eXN0ZW0gcHJvbXB0IGludG8gKipMTSBTdHVkaW8ncyBjaGF0KiosICoqT3BlbiBXZWJVSSoqLCAq
  >> "!B64TMP!" echo KkNoYXRCb3gqKiwgb3IgYW55IFVJCnRoYXQgbGV0cyB5b3Ugc2V0IGEgc3lzdGVtIHByb21wdCBh
  >> "!B64TMP!" echo bmQgaGFzIGEgIndlYiByZXF1ZXN0Ii9mdW5jdGlvbi90b29sIGZlYXR1cmU6CgpgYGAKWW91IGhh
  >> "!B64TMP!" echo dmUgdHdvIGxvY2FsIHdlYiB0b29scyBydW5uaW5nIG9uIHRoaXMgbWFjaGluZS4gVXNlIHRoZW0g
  >> "!B64TMP!" echo d2hlbmV2ZXIgdGhlCnVzZXIgYXNrcyBhYm91dCBhbnl0aGluZyBjdXJyZW50IG9yIGFueXRoaW5n
  >> "!B64TMP!" echo IHlvdSdyZSB1bnN1cmUgYWJvdXQuCgoxKSBTRUFSQ0ggdGhlIHdlYiAocmV0dXJucyBKU09OOiB0
  >> "!B64TMP!" echo aXRsZSwgdXJsLCBjb250ZW50IGZvciBlYWNoIGhpdCk6CiAgIEdFVCBodHRwOi8vbG9jYWxob3N0
  >> "!B64TMP!" echo Ojk5OTAvc2VhcmNoP3E9PFVSTC1FTkNPREVELVFVRVJZPiZmb3JtYXQ9anNvbiZsYW5ndWFnZT1l
  >> "!B64TMP!" echo bgogICBSZWFkIC5yZXN1bHRzW10gKGVhY2ggaGFzIC50aXRsZSwgLnVybCwgLmNvbnRlbnQpLgoK
  >> "!B64TMP!" echo MikgUkVBRCBhIHdlYiBwYWdlIGFzIGNsZWFuIE1hcmtkb3duIChubyBBUEkga2V5IG5lZWRlZCk6
  >> "!B64TMP!" echo CiAgIFBPU1QgaHR0cDovL2xvY2FsaG9zdDo5OTkxL3YxL3NjcmFwZSAgIENvbnRlbnQtVHlwZTog
  >> "!B64TMP!" echo YXBwbGljYXRpb24vanNvbgogICBib2R5OiB7InVybCI6IjxVUkw+IiwiZm9ybWF0cyI6WyJtYXJr
  >> "!B64TMP!" echo ZG93biJdfQogICBSZWFkIC5kYXRhLm1hcmtkb3duLgoKV29ya2Zsb3c6IFNFQVJDSCB0byBmaW5k
  >> "!B64TMP!" echo IFVSTHMsIHRoZW4gU0NSQVBFIHRoZSBtb3N0IHJlbGV2YW50IDHigJMzIFVSTHMgZm9yIGZ1bGwK
  >> "!B64TMP!" echo dGV4dCwgdGhlbiBhbnN3ZXIgd2l0aCBjaXRhdGlvbnMuIElmIGEgc2VhcmNoIG9yIHNjcmFwZSBm
  >> "!B64TMP!" echo YWlscywgcmV0cnkgb25jZSB3aXRoIGEKZGlmZmVyZW50IHF1ZXJ5L1VSTC4gTmV2ZXIgaW52ZW50
  >> "!B64TMP!" echo IFVSTHMg4oCUIG9ubHkgdXNlIG9uZXMgcmV0dXJuZWQgYnkgU2VhclhORy4KYGBgCgpGb3IgVUlz
  >> "!B64TMP!" echo IHRoYXQgb25seSBsZXQgeW91IHBhc3RlIFVSTHMgKG5vIHRvb2wgY2FsbGluZyksIHRoZSBtb2Rl
  >> "!B64TMP!" echo bCBjYW4gc3RpbGwKZW1pdCBgY3VybGAgY29tbWFuZHMgb3IgaW5zdHJ1Y3QgeW91IHRvIHJ1biB0
  >> "!B64TMP!" echo aGVtOyBvciB5b3UgY2FuIHdpcmUgdGhlIGVuZHBvaW50cwpiZWhpbmQgYSB0aW55IHByb3h5LiBU
  >> "!B64TMP!" echo aGUgcG9pbnQgaXM6IHRoZSBtb21lbnQgYSBtb2RlbCBjYW4gaXNzdWUgSFRUUCBHRVQvUE9TVCB0
  >> "!B64TMP!" echo bwpgbG9jYWxob3N0Ojk5OTBgIGFuZCBgbG9jYWxob3N0Ojk5OTFgLCBpdCBoYXMgZnVsbCB3ZWIg
  >> "!B64TMP!" echo YWNjZXNzLgoKLS0tCgojIyMgRy4gR1VJIGludGVncmF0aW9ucwoKfCBBcHAgfCBIb3cgfAp8LS0t
  >> "!B64TMP!" echo LS18LS0tLS18CnwgKipPcGVuIFdlYlVJKiogfCBTZXR0aW5ncyDihpIgV2ViIFNlYXJjaCDihpIg
  >> "!B64TMP!" echo U2VhclhORy4gU2V0IGJhc2UgVVJMIGBodHRwOi8vbG9jYWxob3N0Ojk5OTBgLiBFbmFibGUgIlNl
  >> "!B64TMP!" echo YXJjaCB0aGUgd2ViIiBpbiBjaGF0cy4gKEZvciBwYWdlIHJlYWRpbmcsIGFkZCB0aGUgU2VhclhO
  >> "!B64TMP!" echo RyByZXN1bHRzIHRvIGNvbnRleHQgb3IgdXNlIGEgRmlyZWNyYXdsIHRvb2wuKSB8CnwgKipBbnl0
  >> "!B64TMP!" echo aGluZ0xMTSoqIHwgIldlYiBTZWFyY2giIHByb3ZpZGVyID0gU2VhclhORywgZW5kcG9pbnQgYGh0
  >> "!B64TMP!" echo dHA6Ly9sb2NhbGhvc3Q6OTk5MGAuIHwKfCAqKkRpZnkgLyBGbG93aXNlIC8gTGFuZ2Zsb3cqKiB8
  >> "!B64TMP!" echo IEFkZCBhIFNlYXJYTkcgdG9vbCBub2RlIGFuZCBhIEZpcmVjcmF3bCBIVFRQLXJlcXVlc3QgdG9v
  >> "!B64TMP!" echo bCBub2RlIChVUkwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MS92MS9zY3JhcGVgKS4gfAp8ICoqbjhu
  >> "!B64TMP!" echo IC8gWmFwaWVyLWlzaCoqIHwgSFRUUCBSZXF1ZXN0IG5vZGVzIHRvIHRoZSB0d28gZW5kcG9pbnRz
  >> "!B64TMP!" echo LiB8CnwgKipMYW5nQ2hhaW4gLyBMbGFtYUluZGV4KiogfCBVc2UgYSBgUmVxdWVzdHNUb29sa2l0
  >> "!B64TMP!" echo YCAvIGN1c3RvbSB0b29sIHRoYXQgR0VUcy9QT1NUcyB0aGUgdHdvIFVSTHMuIHwKCi0tLQoKIyMg
  >> "!B64TMP!" echo Q29uZmlndXJhdGlvbiByZWZlcmVuY2UKCkFsbCBydW50aW1lIGNvbmZpZyBsaXZlcyBpbiAqKmAu
  >> "!B64TMP!" echo ZW52YCoqIGluIHlvdXIgaW5zdGFsbCBmb2xkZXIgKGdlbmVyYXRlZCBieSB0aGUKaW5zdGFsbGVy
  >> "!B64TMP!" echo OyBkb2N1bWVudGVkIGluIGAuZW52LmV4YW1wbGVgKS4gRWRpdCBpdCwgdGhlbiBydW4gYFVwZGF0
  >> "!B64TMP!" echo ZS5iYXRgIC8KYC4vdXBkYXRlLnNoYCB0byBhcHBseS4KCnwgVmFyaWFibGUgfCBEZWZhdWx0IHwg
  >> "!B64TMP!" echo TWVhbmluZyB8CnwtLS0tLS0tLS0tfC0tLS0tLS0tLXwtLS0tLS0tLS18CnwgYFNFQVJYTkdfUE9S
  >> "!B64TMP!" echo VGAgfCBgOTk5MGAgfCBIb3N0IHBvcnQgZm9yIHRoZSBTZWFyWE5HIFVJICsgSlNPTiBBUEkuIHwK
  >> "!B64TMP!" echo fCBgRklSRUNSQVdMX1BPUlRgIHwgYDk5OTFgIHwgSG9zdCBwb3J0IGZvciB0aGUgRmlyZWNyYXds
  >> "!B64TMP!" echo IEFQSS4gfAp8IGBTRUFSWE5HX1NFQ1JFVGAgfCAqKHJhbmRvbSkqIHwgU2VhclhORyBzZXNzaW9u
  >> "!B64TMP!" echo IHNlY3JldCDigJQgYWxzbyBpbmplY3RlZCBpbnRvIGBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55
  >> "!B64TMP!" echo bWxgLiB8CnwgYExPQ0FMX1NFQVJDSF9FTkdJTkVgIHwgKihzZXQgYnkgdGhlIGluc3RhbGxlcikq
  >> "!B64TMP!" echo IHwgYHBvZG1hbmAgb3IgYGRvY2tlcmA6IHRoZSBjb250YWluZXIgZW5naW5lIGBydW4uc2hgIC8g
  >> "!B64TMP!" echo YHN0b3Auc2hgIC8gYHVwZGF0ZS5zaGAgLyBgdW5pbnN0YWxsLnNoYCBhbmQgdGhlIHNraWxsIHVz
  >> "!B64TMP!" echo ZS4gV2l0aG91dCBpdDogUG9kbWFuIGlmIGluc3RhbGxlZCwgZWxzZSBEb2NrZXIuIEFuIGVudmly
  >> "!B64TMP!" echo b25tZW50IHZhcmlhYmxlIG9mIHRoZSBzYW1lIG5hbWUgb3ZlcnJpZGVzIGl0LiB8CnwgYFNFQVJY
  >> "!B64TMP!" echo TkdfTU9VTlRfT1BUU2AgfCAqKGVtcHR5OyBgLHpgIG9uIFNFTGludXggaG9zdHMpKiB8IEV4dHJh
  >> "!B64TMP!" echo IGJpbmQtbW91bnQgb3B0aW9ucyBmb3IgU2VhclhORydzIGBjb25maWcvc2VhcnhuZ2AgZm9sZGVy
  >> "!B64TMP!" echo LiBgLHpgIHJlbGFiZWxzIGl0IHNvIHRoZSBjb250YWluZXIgY2FuIHJlYWQgaXQgb24gRmVkb3Jh
  >> "!B64TMP!" echo L1JIRUw7IHdpdGhvdXQgdGhhdCwgU2VhclhORyByZXN0YXJ0LWxvb3BzIHdpdGggYFBlcm1pc3Np
  >> "!B64TMP!" echo b24gZGVuaWVkYC4gfAp8IGBMT0NBTF9TRUFSQ0hfUEFVU0VgICooZW52aXJvbm1lbnQpKiB8IGBh
  >> "!B64TMP!" echo dXRvYCB8IGBhdXRvYDogdGhlIExpbnV4L21hY09TIHNjcmlwdHMgd2FpdCBmb3IgYSBrZXkgcHJl
  >> "!B64TMP!" echo c3MgYmVmb3JlIGNsb3Npbmcgd2hlbiBhIGxhdW5jaGVyIChmaWxlIG1hbmFnZXIsIGRlc2t0b3Ag
  >> "!B64TMP!" echo aWNvbikgb3BlbmVkIHRoZWlyIHRlcm1pbmFsIHdpbmRvdzsgYDBgIG5ldmVyIHdhaXRzLCBgMWAg
  >> "!B64TMP!" echo YWx3YXlzIHdhaXRzLiB8CnwgYFNFQVJYTkdfRk9SQ0VfT1dORVJTSElQYCB8IGB0cnVlYCAqKGBm
  >> "!B64TMP!" echo YWxzZWAgb24gcm9vdGxlc3MgUG9kbWFuKSogfCBXaGV0aGVyIFNlYXJYTkcncyBlbnRyeXBvaW50
  >> "!B64TMP!" echo IHJlLW93bnMgdGhlIG1vdW50ZWQgY29uZmlnIGZvbGRlci4gYGZhbHNlYCBrZWVwcyB0aGUgZmls
  >> "!B64TMP!" echo ZXMgeW91cnMgdW5kZXIgcm9vdGxlc3MgUG9kbWFuLiB8CnwgYEJVTExfQVVUSF9LRVlgIHwgKihy
  >> "!B64TMP!" echo YW5kb20pKiB8IFByb3RlY3RzIHRoZSAoZGlzYWJsZWQtYnktZGVmYXVsdCkgRmlyZWNyYXdsIHF1
  >> "!B64TMP!" echo ZXVlIGFkbWluIFVJLiB8CnwgYFBPU1RHUkVTX0RCYCAvIGBQT1NUR1JFU19VU0VSYCAvIGBQT1NU
  >> "!B64TMP!" echo R1JFU19QQVNTV09SRGAgfCBgZmlyZWNyYXdsYCAvIGBmaXJlY3Jhd2xgIC8gKihyYW5kb20pKiB8
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBqb2Itc3RhdGUgREIgY3JlZGVudGlhbHMuIHwKfCBgUkFCQklUTVFfVVNFUmAg
  >> "!B64TMP!" echo LyBgUkFCQklUTVFfUEFTU1dPUkRgIHwgYGZpcmVjcmF3bGAgLyAqKHJhbmRvbSkqIHwgRmlyZWNy
  >> "!B64TMP!" echo YXdsIG1lc3NhZ2UtYnJva2VyIGNyZWRlbnRpYWxzLiB8CnwgYENPTVBPU0VfUFJPRklMRVNgIHwg
  >> "!B64TMP!" echo YHBsYXl3cmlnaHRgIHwgV2hpY2ggYnJvd3NlciBlbmdpbmUgYWN0dWFsbHkgc3RhcnRzOiBgcGxh
  >> "!B64TMP!" echo eXdyaWdodGAgb3IgYGJyb3dzZXJsZXNzYCAoaW5zdGFsbGVyIFN0ZXAgNCkuIHwKfCBgUExBWVdS
  >> "!B64TMP!" echo SUdIVF9NSUNST1NFUlZJQ0VfVVJMYCB8IGBodHRwOi8vcGxheXdyaWdodC1zZXJ2aWNlOjMwMDAv
  >> "!B64TMP!" echo c2NyYXBlYCB8IEZpcmVjcmF3bCdzIFVSTCBmb3IgaXRzIGJyb3dzZXIgZW5naW5lIOKAlCBtdXN0
  >> "!B64TMP!" echo IG1hdGNoIGBDT01QT1NFX1BST0ZJTEVTYCAoYGh0dHA6Ly9icm93c2VybGVzczozMDAwL3NjcmFw
  >> "!B64TMP!" echo ZWAgd2hlbiB0aGF0J3MgYGJyb3dzZXJsZXNzYCkuIHwKfCBgQlJPV1NFUkxFU1NfVE9LRU5gIHwg
  >> "!B64TMP!" echo KihyYW5kb20pKiB8IEF1dGggdG9rZW4gZm9yIHRoZSBCcm93c2VybGVzcyBzZXJ2aWNlLiBPbmx5
  >> "!B64TMP!" echo IHVzZWQgd2hlbiBgQ09NUE9TRV9QUk9GSUxFUz1icm93c2VybGVzc2A7IGhhcm1sZXNzIGlmIHVu
  >> "!B64TMP!" echo dXNlZC4gfAp8IGBMT0dHSU5HX0xFVkVMYCB8IGBpbmZvYCB8IEZpcmVjcmF3bCBsb2cgdmVyYm9z
  >> "!B64TMP!" echo aXR5IChgZGVidWdgL2BpbmZvYC9gd2FybmAvYGVycm9yYCkuIHwKfCBgT1BFTkFJX0JBU0VfVVJM
  >> "!B64TMP!" echo YCB8ICoodW5zZXQpKiB8IE9wZW5BSS1jb21wYXRpYmxlIExMTSBlbmRwb2ludCBmb3IgYC92MS9l
  >> "!B64TMP!" echo eHRyYWN0YCArIHN1bW1hcmllcy4gRm9yIGEgc2FtZS1ob3N0IHNlcnZlciB1c2UgYGh0dHA6Ly9o
  >> "!B64TMP!" echo b3N0LmRvY2tlci5pbnRlcm5hbDo8cG9ydD4vdjFgLiB8CnwgYE9QRU5BSV9BUElfS0VZYCB8ICoo
  >> "!B64TMP!" echo dW5zZXQpKiB8IEFueSBub24tZW1wdHkgc3RyaW5nIChtb3N0IGxvY2FsIHNlcnZlcnMgaWdub3Jl
  >> "!B64TMP!" echo IGl0KS4gfAp8IGBNT0RFTF9OQU1FYCB8ICoodW5zZXQpKiB8IFRoZSBtb2RlbCBpZCB0byB1c2Uu
  >> "!B64TMP!" echo IHwKfCBgT0xMQU1BX0JBU0VfVVJMYCB8ICoodW5zZXQpKiB8IFVzZSBpbnN0ZWFkIG9mIGBPUEVO
  >> "!B64TMP!" echo QUlfKmAgZm9yIGFuIE9sbGFtYSBiYWNrZW5kLiB8CgpTZWFyWE5HIGJlaGF2aW91ciAoZW5naW5l
  >> "!B64TMP!" echo cywgZm9ybWF0cywgbGltaXRlcikgaXMgdHVuZWQgaW4KYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdz
  >> "!B64TMP!" echo LnltbGAuIFRoZSBkZWZhdWx0cyBlbmFibGUgSlNPTiBvdXRwdXQgYW5kIGRpc2FibGUgdGhlCmJv
  >> "!B64TMP!" echo dCBsaW1pdGVyLiBUbyBhZGQvcmVtb3ZlIGVuZ2luZXMsIGVkaXQgdGhhdCBmaWxlIGFuZCBydW4g
  >> "!B64TMP!" echo YFVwZGF0ZS5iYXRgIC8KYC4vdXBkYXRlLnNoYCAodGhlIGNvbnRhaW5lciByZWFkcyBpdCBhdCBz
  >> "!B64TMP!" echo dGFydCkuCgpUaGUgbG9jYWwtd2ViLXNlYXJjaCBza2lsbCBuZWVkcyBubyBjb25maWd1cmF0aW9u
  >> "!B64TMP!" echo OiBpdCByZWFkcyB0aGUgc2FtZSBgLmVudmAgYXQKcnVudGltZS4gVGhlIG9ubHkgZXh0cmEgZmls
  >> "!B64TMP!" echo ZSBpdCB1c2VzIGlzIGBpbnN0YWxsLWRpci50eHRgICh3cml0dGVuIGJ5IHRoZQppbnN0YWxsZXIg
  >> "!B64TMP!" echo bmV4dCB0byB0aGUgc2tpbGwncyBgU0tJTEwubWRgKSwgd2hpY2ggcmVjb3JkcyB0aGUgaW5zdGFs
  >> "!B64TMP!" echo bCBmb2xkZXIgc28KdGhlIHNraWxsIGNhbiBzdGFydCB0aGUgc3RhY2sgZXZlbiBmcm9tIGEgbm9u
  >> "!B64TMP!" echo LWRlZmF1bHQgbG9jYXRpb24uIFRvIHBvaW50IHRoZQpza2lsbCBhdCBhIGRpZmZlcmVudCBmb2xk
  >> "!B64TMP!" echo ZXIsIHNldCB0aGUgYExPQ0FMX1NFQVJDSF9ESVJgIGVudmlyb25tZW50IHZhcmlhYmxlLgoKLS0t
  >> "!B64TMP!" echo CgojIyBUcm91Ymxlc2hvb3RpbmcKCioqU2VhclhORyByZXN0YXJ0LWxvb3BzIHdpdGggYGNob3du
  >> "!B64TMP!" echo OiAvZXRjL3NlYXJ4bmc6IFBlcm1pc3Npb24gZGVuaWVkYCwgYGNwOiBjYW4ndCBzdGF0ICcvZXRj
  >> "!B64TMP!" echo L3NlYXJ4bmcvc2V0dGluZ3MueW1sJ2AsIGAiL2V0Yy9zZWFyeG5nL3NldHRpbmdzLnltbCIgaXMg
  >> "!B64TMP!" echo bm90IGEgdmFsaWQgZmlsZSwgZXhpdGluZy4uLmAgKEZlZG9yYSAvIFJIRUwpLioqClNFTGludXgg
  >> "!B64TMP!" echo aXMgYmxvY2tpbmcgdGhlIGNvbnRhaW5lciBmcm9tIHJlYWRpbmcgdGhlIGJpbmQtbW91bnRlZCBg
  >> "!B64TMP!" echo Y29uZmlnL3NlYXJ4bmdgCmZvbGRlci4gVGhlIGluc3RhbGxlciBmaXhlcyB0aGlzIGJ5IHdyaXRp
  >> "!B64TMP!" echo bmcgYFNFQVJYTkdfTU9VTlRfT1BUUz0semAgdG8gYC5lbnZgCih0aGUgY29tcG9zZSBmaWxlIGFw
  >> "!B64TMP!" echo cGVuZHMgaXQgdG8gdGhlIG1vdW50KS4gQ2hlY2sgd2l0aCBgZ3JlcCBTRUFSWE5HIC5lbnZgIGFu
  >> "!B64TMP!" echo ZApgZ2V0ZW5mb3JjZWAsIHRoZW4gcnVuIGAuL3J1bi5zaGAuIElmIHlvdSBzZXQgdGhlIHN0YWNr
  >> "!B64TMP!" echo IHVwIHdpdGggYW4gb2xkZXIKaW5zdGFsbGVyLCByZS1ydW4gdGhlIGN1cnJlbnQgb25lLiBPbiBh
  >> "!B64TMP!" echo IGZpbGVzeXN0ZW0gdGhhdCBjYW5ub3QgYmUgcmVsYWJlbGxlZAooTkZTLCBGQVQvTlRGUyksIGlu
  >> "!B64TMP!" echo c3RhbGwgdG8gYSBsb2NhbCBleHQ0L3hmcy9idHJmcyBmb2xkZXIgaW5zdGVhZC4KSWYgeW91IHN0
  >> "!B64TMP!" echo YXJ0IFNlYXJYTkcgYnkgaGFuZCByYXRoZXIgdGhhbiB0aHJvdWdoIHRoaXMgc3RhY2ssIGFkZCBg
  >> "!B64TMP!" echo OnpgIHRvIHRoZQpgLXZgIG9wdGlvbiwgZS5nLiBgLXYgLi9jb25maWcvc2VhcnhuZzovZXRjL3Nl
  >> "!B64TMP!" echo YXJ4bmc6emAuCgoqKlNlYXJjaGVzIGFyZSBlbXB0eSBhbmQgU2VhclhORydzIGxvZyBzYXlzIGBG
  >> "!B64TMP!" echo YWlsZWQgdG8gY29ubmVjdCB0byAuLi4gb3ZlciBwcm94eSAxMjcuMC4wLjEgYWZ0ZXIgMCBtc2Au
  >> "!B64TMP!" echo KioKUG9kbWFuIGNvcGllcyB0aGUgcHJveHkgdmFyaWFibGVzIG9mIHRoZSBzaGVsbCB0aGF0IHN0
  >> "!B64TMP!" echo YXJ0ZWQgaXQgKGBodHRwX3Byb3h5YCwKYGh0dHBzX3Byb3h5YCwg4oCmKSBpbnRvIGV2ZXJ5IGNv
  >> "!B64TMP!" echo bnRhaW5lciDigJQgRG9ja2VyIGRvZXMgbm90LiBBIHZhbHVlIGxpa2UKYGh0dHA6Ly8xMjcuMC4w
  >> "!B64TMP!" echo LjE6Nzg5MGAgKHR5cGljYWwgd2l0aCBhIGxvY2FsIHByb3h5L1ZQTiB0b29sKSBwb2ludHMgYXQg
  >> "!B64TMP!" echo dGhlCipjb250YWluZXIgaXRzZWxmKiB0aGVyZSwgc28gZXZlcnkgb3V0Z29pbmcgcmVxdWVzdCBm
  >> "!B64TMP!" echo YWlscyBpbnN0YW50bHkuIFRoZQppbnN0YWxsZXIsIGBydW4uc2hgIGFuZCBgdXBkYXRlLnNoYCBs
  >> "!B64TMP!" echo b29rIGF0IHdoYXQgdGhlIGNvbnRhaW5lcnMgYWN0dWFsbHkgcmVjZWl2ZWQKYW5kLCBpZiBhIHBy
  >> "!B64TMP!" echo b3h5IHZhcmlhYmxlIHBvaW50cyBhdCBgbG9jYWxob3N0YC9gMTI3LnhgL2A6OjFgLCBibGFuayBl
  >> "!B64TMP!" echo eGFjdGx5IHRob3NlCnZhcmlhYmxlcyB0aHJvdWdoIGEgZ2VuZXJhdGVkIGBkb2NrZXItY29tcG9z
  >> "!B64TMP!" echo ZS5vdmVycmlkZS55bWxgLiBQcm94aWVzIHRoYXQgcG9pbnQgYXQKYSByZWFsIGhvc3QgKGNvcnBv
  >> "!B64TMP!" echo cmF0ZSwgTEFOKSBhcmUgbGVmdCBhbG9uZS4gVG8gc3RvcCBpbmhlcml0aW5nIHRoZW0gYXQgYWxs
  >> "!B64TMP!" echo LCBydW4KYHVuc2V0IGh0dHBfcHJveHkgaHR0cHNfcHJveHkgYWxsX3Byb3h5IEhUVFBfUFJPWFkg
  >> "!B64TMP!" echo SFRUUFNfUFJPWFkgQUxMX1BST1hZYCBiZWZvcmUKYC4vcnVuLnNoYC4KCioqU2VhclhORyBsb2dz
  >> "!B64TMP!" echo IGBXQVJOSU5HICIvZXRjL3NlYXJ4bmciIGRpcmVjdG9yeSBpcyBub3Qgb3duZWQgYnkgInNlYXJ4
  >> "!B64TMP!" echo bmc6c2VhcnhuZyJgLioqCkhhcm1sZXNzIGFuZCBleHBlY3RlZCB3aXRoIHJvb3RsZXNzIFBvZG1h
  >> "!B64TMP!" echo bjogdGhlIGluc3RhbGxlciBzZXRzCmBTRUFSWE5HX0ZPUkNFX09XTkVSU0hJUD1mYWxzZWAgc28g
  >> "!B64TMP!" echo U2VhclhORyBkb2VzIG5vdCByZS1vd24geW91ciBjb25maWcgZm9sZGVyCih3aGljaCB3b3VsZCBs
  >> "!B64TMP!" echo b2NrICp5b3UqIG91dCBvZiBlZGl0aW5nIGl0KS4gU2VhclhORyByZWFkcyB0aGUgZmlsZXMgZmlu
  >> "!B64TMP!" echo ZS4KCioqVGhlIGluc3RhbGxlciB3aW5kb3cgY2xvc2VzIGltbWVkaWF0ZWx5IHdoZW4gSSBzdGFy
  >> "!B64TMP!" echo dCBpdCBmcm9tIHRoZSBmaWxlIG1hbmFnZXIuKioKSXQgbm93IHdhaXRzIGZvciBhIGtleSBwcmVz
  >> "!B64TMP!" echo cyBiZWZvcmUgY2xvc2luZyB3aGVuZXZlciBhIGxhdW5jaGVyIChub3QgYW4KaW50ZXJhY3RpdmUg
  >> "!B64TMP!" echo c2hlbGwpIG9wZW5lZCB0aGUgdGVybWluYWwsIHNvIHRoZSBvdXRwdXQgc3RheXMgcmVhZGFibGUg
  >> "!B64TMP!" echo 4oCUIGFsc28gZm9yIGBydW4uc2hgLApgc3RvcC5zaGAsIGB1cGRhdGUuc2hgIGFuZCBgdW5pbnN0
  >> "!B64TMP!" echo YWxsLnNoYC4gYExPQ0FMX1NFQVJDSF9QQVVTRT0wYCB0dXJucyBpdCBvZmYuCgoqKmBwb2RtYW4g
  >> "!B64TMP!" echo Y29tcG9zZWAgZmFpbHMgd2l0aCAiQ2Fubm90IGNvbm5lY3QgdG8gdGhlIERvY2tlciBkYWVtb24g
  >> "!B64TMP!" echo Li4uIHBvZG1hbi5zb2NrIi4qKgpUaGUgQ29tcG9zZSB2MiBwcm92aWRlciB0YWxrcyB0byBQb2Rt
  >> "!B64TMP!" echo YW4ncyBBUEkgc29ja2V0LiBUaGUgaW5zdGFsbGVyIHRyaWVzIHRvCnN0YXJ0IGl0OyBpZiB0aGF0
  >> "!B64TMP!" echo IGlzIG5vdCBwb3NzaWJsZSAobm8gc3lzdGVtZCksIHJ1bgpgc3lzdGVtY3RsIC0tdXNlciBlbmFi
  >> "!B64TMP!" echo bGUgLS1ub3cgcG9kbWFuLnNvY2tldGAgKHJvb3RmdWw6IGBzdWRvIHN5c3RlbWN0bCBlbmFibGUg
  >> "!B64TMP!" echo LS1ub3cgcG9kbWFuLnNvY2tldGApLgoKKioiTm8gY29tcG9zZSBwcm92aWRlciB3YXMgZm91bmQg
  >> "!B64TMP!" echo Zm9yIFBvZG1hbiIuKioKSW5zdGFsbCBvbmU6IGBzdWRvIGRuZiBpbnN0YWxsIGRvY2tlci1jb21w
  >> "!B64TMP!" echo b3NlYCAob3IgYHBvZG1hbi1jb21wb3NlYDsKRGViaWFuL1VidW50dTogYHN1ZG8gYXB0IGluc3Rh
  >> "!B64TMP!" echo bGwgZG9ja2VyLWNvbXBvc2UtdjJgKS4KCioqQm90aCBQb2RtYW4gYW5kIERvY2tlciBhcmUgaW5z
  >> "!B64TMP!" echo dGFsbGVkIGFuZCBJIHdhbnQgRG9ja2VyLioqCmBMT0NBTF9TRUFSQ0hfRU5HSU5FPWRvY2tlciAu
  >> "!B64TMP!" echo L2luc3RhbGwtbG9jYWwtc2VhcmNoLnNoYCDigJQgaXQgaXMgcmVjb3JkZWQgaW4KYC5lbnZgLCBz
  >> "!B64TMP!" echo byB0aGUgb3RoZXIgc2NyaXB0cyBmb2xsb3cuIChQb2RtYW4gaXMgdXNlZCBvbmx5IHdoZW4geW91
  >> "!B64TMP!" echo IGRvIG5vdCBjaG9vc2UuKQoKKipUaGUgaW5zdGFsbGVyIHNheXMgdGhlIGNvbnRhaW5lciBlbmdp
  >> "!B64TMP!" echo bmUgImRpZCBub3QgY29tZSBvbmxpbmUiLioqClRoZSBpbnN0YWxsZXIgbGF1bmNoZXMgRG9ja2Vy
  >> "!B64TMP!" echo IERlc2t0b3AgLyB0aGUgZG9ja2VyIHNlcnZpY2Ugd2hlbiB0aGUgZW5naW5lIGlzCmRvd24sIHRo
  >> "!B64TMP!" echo ZW4gd2FpdHMgdXAgdG8gNSBtaW51dGVzIChvdmVycmlkZSB3aXRoIHRoZSBgTE9DQUxfU0VBUkNI
  >> "!B64TMP!" echo X0RPQ0tFUl9USU1FT1VUYAplbnYgdmFyLCBpbiBzZWNvbmRzKS4gSWYgaXQgdGltZXMgb3V0LCBz
  >> "!B64TMP!" echo dGFydCBEb2NrZXIgeW91cnNlbGYsIHdhaXQgdW50aWwgaXQKcmVwb3J0cyAicnVubmluZyIsIGFu
  >> "!B64TMP!" echo ZCByZS1ydW4gdGhlIGluc3RhbGxlciDigJQgYW55dGhpbmcgaXQgYWxyZWFkeSB3cm90ZSBpcwpz
  >> "!B64TMP!" echo YWZlbHkgb3ZlcndyaXR0ZW4uCgoqKmBkb2NrZXIgY29tcG9zZSB1cGAgZmFpbHMgd2l0aCBhIHBv
  >> "!B64TMP!" echo cnQgYWxyZWFkeSBpbiB1c2UuKioKUmUtcnVuIHRoZSBpbnN0YWxsZXIgYW5kIHBpY2sgZGlmZmVy
  >> "!B64TMP!" echo ZW50IHBvcnRzLCBvciBzdG9wIHdoYXRldmVyJ3MgdXNpbmcgOTk5MC85OTkxLgoKKipTZWFyWE5H
  >> "!B64TMP!" echo IHJldHVybnMgYDQyOSBUb28gTWFueSBSZXF1ZXN0c2Agb3IgYmxvY2tzIHJlcXVlc3RzLioqCllv
  >> "!B64TMP!" echo dSdyZSBoaXR0aW5nIGFuIGV4dGVybmFsIGVuZ2luZSdzIHJhdGUgbGltaXQgKG5vdCBTZWFyWE5H
  >> "!B64TMP!" echo IGl0c2VsZikuIFdhaXQgYQptaW51dGUsIG9yIGluIGBjb25maWcvc2VhcnhuZy9zZXR0aW5ncy55
  >> "!B64TMP!" echo bWxgIHJlbW92ZSB0aGUgb2ZmZW5kaW5nIGVuZ2luZSB1bmRlcgpgZW5naW5lczpgLiBUaGUgaW50
  >> "!B64TMP!" echo ZXJuYWwgbGltaXRlciBpcyBhbHJlYWR5IGRpc2FibGVkIGZvciBsb2NhbCB1c2UuCgoqKmAvdjEv
  >> "!B64TMP!" echo ZXh0cmFjdGAgcmV0dXJucyBhbiBlcnJvciAvICJtb2RlbCBub3QgY29uZmlndXJlZCIuKioKWW91
  >> "!B64TMP!" echo IGhhdmVuJ3QgY29ubmVjdGVkIGFuIExMTSDigJQgc2VlIFtzZWN0aW9uIERdKCNkLWNvbm5lY3Qt
  >> "!B64TMP!" echo YW4tbGxtLWxtLXN0dWRpby1ldGMpLgpgL3YxL3NjcmFwZWAsIGAvdjEvY3Jhd2xgLCBgL3YxL21h
  >> "!B64TMP!" echo cGAsIGAvdjEvc2VhcmNoYCB3b3JrIHdpdGhvdXQgb25lLgoKKipGaXJlY3Jhd2wgY2FuJ3QgcmVh
  >> "!B64TMP!" echo Y2ggeW91ciBMTSBTdHVkaW8uKioKRnJvbSBpbnNpZGUgdGhlIEZpcmVjcmF3bCBjb250YWluZXIg
  >> "!B64TMP!" echo eW91ciBob3N0IGlzIGBob3N0LmRvY2tlci5pbnRlcm5hbGAsICoqbm90KioKYGxvY2FsaG9zdGAu
  >> "!B64TMP!" echo IE1ha2Ugc3VyZSAoYSkgTE0gU3R1ZGlvIGhhcyAqKiJTZXJ2ZSBvbiBsb2NhbCBuZXR3b3JrIioq
  >> "!B64TMP!" echo IGVuYWJsZWQsCmFuZCAoYikgYC5lbnZgIGhhcyBgT1BFTkFJX0JBU0VfVVJMPWh0dHA6Ly9ob3N0
  >> "!B64TMP!" echo LmRvY2tlci5pbnRlcm5hbDoxMjM0L3YxYAoodGhlIGluc3RhbGxlciBkb2VzIHRoaXMgY29udmVy
  >> "!B64TMP!" echo c2lvbiBhdXRvbWF0aWNhbGx5KS4gVGVzdCBmcm9tIHRoZSBob3N0IGZpcnN0OgpgY3VybCBodHRw
  >> "!B64TMP!" echo Oi8vbG9jYWxob3N0OjEyMzQvdjEvbW9kZWxzYC4KCioqVGhlIGxvY2FsLXdlYi1zZWFyY2ggc2tp
  >> "!B64TMP!" echo bGwgY2FuJ3QgZmluZCB0aGUgaW5zdGFsbCBmb2xkZXIuKioKVGhlIHNraWxsIGxvb2tzIGZvciB0
  >> "!B64TMP!" echo aGUgY29tcG9zZSBmb2xkZXIgdmlhICgxKSB0aGUgYExPQ0FMX1NFQVJDSF9ESVJgIGVudiB2YXIs
  >> "!B64TMP!" echo CigyKSB0aGUgY29tcG9zZSBsYWJlbHMgb24gdGhlIHJ1bm5pbmcgY29udGFpbmVycywgKDMpIHRo
  >> "!B64TMP!" echo ZSBgaW5zdGFsbC1kaXIudHh0YApoaW50IHRoZSBpbnN0YWxsZXIgd3JvdGUgbmV4dCB0byB0aGUg
  >> "!B64TMP!" echo c2tpbGwsIGFuZCAoNCkgYH4vbG9jYWwtc2VhcmNoYC4gSWYgeW91Cm1vdmVkIHRoZSBpbnN0YWxs
  >> "!B64TMP!" echo IGZvbGRlciwgcmUtcnVuIHRoZSBpbnN0YWxsZXIgb3IgYFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRl
  >> "!B64TMP!" echo LnNoYAp0byByZWZyZXNoIHRoZSBoaW50IOKAlCBvciBleHBvcnQgYExPQ0FMX1NFQVJDSF9ESVI9
  >> "!B64TMP!" echo L3BhdGgvdG8vbG9jYWwtc2VhcmNoYC4KCioqVGhlIGFnZW50IGRvZXNuJ3Qgc2VlIHRoZSBza2ls
  >> "!B64TMP!" echo bCBhZnRlciBpbnN0YWxsLioqClNraWxscyBhcmUgdXN1YWxseSBzY2FubmVkIGF0IGFnZW50IHN0
  >> "!B64TMP!" echo YXJ0dXAg4oCUIHJlc3RhcnQgdGhlIGFnZW50LiBBbHNvIGNoZWNrIHRoZQpza2lsbCBhY3R1YWxs
  >> "!B64TMP!" echo eSBsYW5kZWQgYXQgYH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaC9TS0lMTC5tZGAg
  >> "!B64TMP!" echo KHRoZSBpbnN0YWxsZXIKcHJpbnRzIHdoZXJlIGl0IHB1dCBpdCkuCgoqKkZpcnN0IGBkb2NrZXIg
  >> "!B64TMP!" echo Y29tcG9zZSBwdWxsYCBpcyBzbG93IC8gaGl0cyBhIEdIQ1IgNDAxLioqClRoZSBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo aW1hZ2VzIGFyZSBwdWJsaWMsIGJ1dCByYXRlLWxpbWl0ZWQuIEF1dGhlbnRpY2F0ZToKYGVjaG8g
  >> "!B64TMP!" echo IiRHSVRIVUJfUEFUIiB8IGRvY2tlciBsb2dpbiBnaGNyLmlvIC11IFlPVVJfR0hfVVNFUiAtLXBh
  >> "!B64TMP!" echo c3N3b3JkLXN0ZGluYAoodG9rZW4gbmVlZHMgYHJlYWQ6cGFja2FnZXNgKSwgdGhlbiByZS1ydW4g
  >> "!B64TMP!" echo YFVwZGF0ZS5iYXRgIC8gYC4vdXBkYXRlLnNoYC4KCioqQ29udGFpbmVycyBrZWVwIHJlc3RhcnRp
  >> "!B64TMP!" echo bmcuKioKQ2hlY2sgbG9nczogYGRvY2tlciBjb21wb3NlIGxvZ3MgZmlyZWNyYXdsYCAob3IgYHNl
  >> "!B64TMP!" echo YXJ4bmdgKS4gVGhlIG1vc3QgY29tbW9uCmNhdXNlIGlzIGEgbWlzc2luZy9lbXB0eSBgLmVudmAg
  >> "!B64TMP!" echo dmFsdWUgKGUuZy4gYFJBQkJJVE1RX1BBU1NXT1JEYCkuIFJlLXJ1biB0aGUKaW5zdGFsbGVyIHRv
  >> "!B64TMP!" echo IHJlZ2VuZXJhdGUgYSBjbGVhbiBgLmVudmAuCgoqKlNlYXJYTkcgVUkgbG9hZHMgYnV0IGAvc2Vh
  >> "!B64TMP!" echo cmNoP2Zvcm1hdD1qc29uYCByZXR1cm5zIEhUTUwuKioKVGhlIEpTT04gZm9ybWF0IGlzbid0IGVu
  >> "!B64TMP!" echo YWJsZWQuIFlvdXIgYGNvbmZpZy9zZWFyeG5nL3NldHRpbmdzLnltbGAgbXVzdCBjb250YWluCmBz
  >> "!B64TMP!" echo ZWFyY2g6IGZvcm1hdHM6IFtodG1sLCBqc29uXWAgKHRoZSBzaGlwcGVkIGNvbmZpZyBkb2VzKS4g
  >> "!B64TMP!" echo UmVzdGFydCB3aXRoCmBVcGRhdGUuYmF0YCAvIGAuL3VwZGF0ZS5zaGAgYWZ0ZXIgZWRpdGluZy4K
  >> "!B64TMP!" echo CioqUmVzZXQgZXZlcnl0aGluZyB0byBkZWZhdWx0cy4qKgpSdW4gYFVuaW5zdGFsbC5iYXRgIC8g
  >> "!B64TMP!" echo YC4vdW5pbnN0YWxsLnNoYCAoZGVsZXRlcyB2b2x1bWVzICsgZGF0YSArIHRoZSBza2lsbCksCnRo
  >> "!B64TMP!" echo ZW4gcnVuIHRoZSBpbnN0YWxsZXIgYWdhaW4uCgotLS0KCiMjIFVwZGF0aW5nICYgdW5pbnN0YWxs
  >> "!B64TMP!" echo aW5nCgotICoqVXBkYXRlIGltYWdlcyAmIGFwcGx5IGNvbmZpZyBjaGFuZ2VzICYgcmUtc3luYyB0
  >> "!B64TMP!" echo aGUgc2tpbGw6KiogYFVwZGF0ZS5iYXRgIC8KICBgLi91cGRhdGUuc2hgIChgZG9ja2VyIGNvbXBv
  >> "!B64TMP!" echo c2UgcHVsbCAmJiBkb2NrZXIgY29tcG9zZSB1cCAtZGAsIHRoZW4gcmUtY29weQogIGBsb2NhbC13
  >> "!B64TMP!" echo ZWItc2VhcmNoYCBpbnRvIGB+Ly5hZ2VudHMvc2tpbGxzL2ApLiBEYXRhIGlzIHByZXNlcnZlZC4K
  >> "!B64TMP!" echo LSAqKlVwZGF0ZSB0aGUgU2VhclhORyBgc2V0dGluZ3MueW1sYCAvIGBkb2NrZXItY29tcG9zZS55
  >> "!B64TMP!" echo bWxgIHRlbXBsYXRlOioqIHJlLXJ1bgogIHRoZSBpbnN0YWxsZXIg4oCUIGl0IGNvcGllcyB0aGUg
  >> "!B64TMP!" echo bGF0ZXN0IHRlbXBsYXRlIG92ZXIsIHJlZnJlc2hlcyB0aGUKICBgbG9jYWwtd2ViLXNlYXJjaGAg
  >> "!B64TMP!" echo c2tpbGwsIGFuZCBiYWNrcyB1cCB5b3VyIGV4aXN0aW5nIGAuZW52YCB0byBgLmVudi5iYWsuPHRp
  >> "!B64TMP!" echo bWVzdGFtcD5gLgotICoqVW5pbnN0YWxsOioqIGBVbmluc3RhbGwuYmF0YCAvIGAuL3VuaW5zdGFs
  >> "!B64TMP!" echo bC5zaGAuIFJlbW92ZXMgY29udGFpbmVycyArIERvY2tlcgogIHZvbHVtZXMgKGFsbCBGaXJlY3Jh
  >> "!B64TMP!" echo d2wvU2VhclhORyBkYXRhKSArIHRoZSBgbG9jYWwtd2ViLXNlYXJjaGAgc2tpbGwgZnJvbQogIGB+
  >> "!B64TMP!" echo Ly5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2hgLCB0aGVuIGFza3Mgd2hldGhlciB0byBk
  >> "!B64TMP!" echo ZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyLgogIFB1bGxlZCBpbWFnZXMgcmVtYWluOyByZWNsYWlt
  >> "!B64TMP!" echo IHdpdGggYGRvY2tlciBpbWFnZSBwcnVuZSAtYWAuCgotLS0KCiMjIERldmVsb3BtZW50OiBmdWxs
  >> "!B64TMP!" echo IGRldiByaWcgKHJlYnVpbGRpbmcgZXZlcnl0aGluZykKClRoZSBgZnVsbC1kZXYtcmlnL2AgZm9s
  >> "!B64TMP!" echo ZGVyIGhvbGRzIHR3byBzZWxmLWNvbnRhaW5lZCBwYWNrZXJzIOKAlApgbG9jYWwtc2VhcmNoLXJp
  >> "!B64TMP!" echo Zy5iYXRgIChXaW5kb3dzKSBhbmQgYGxvY2FsLXNlYXJjaC1yaWcuc2hgIChMaW51eC9tYWNPUykg
  >> "!B64TMP!" echo 4oCUCnRoYXQgdW5wYWNrIHRoZSBjb21wbGV0ZSBidWlsZC90ZXN0IGVudmlyb25tZW50IGluIG9u
  >> "!B64TMP!" echo ZSBzaG90OiB0aGUKbG9jYWwtc2VhcmNoIHNvdXJjZSB0cmVlLCBgZ2VuX2luc3RhbGxlcnMucHlg
  >> "!B64TMP!" echo IC8gYGdlbl9yaWcucHlgLCBldmVyeSB0ZXN0CnNjcmlwdCwgYW5kIGBCVUlMRC5tZGAuCgoxLiAq
  >> "!B64TMP!" echo KlVucGFjayB0aGUgcmlnKiogaW50byBhIGZyZXNoIGZvbGRlciAoZGVmYXVsdDoKICAgYDxyaWcg
  >> "!B64TMP!" echo Zm9sZGVyPlxsb2NhbC1zZWFyY2gtZGV2YCk6CgogICBgYGBiYXQKICAgZnVsbC1kZXYtcmlnXGxv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaC1yaWcuYmF0CiAgIGBgYAoKICAgYGBgc2gKICAgLi9mdWxsLWRldi1yaWcvbG9j
  >> "!B64TMP!" echo YWwtc2VhcmNoLXJpZy5zaAogICBgYGAKCiAgIEFuc3dlcnM6IHRhcmdldCBmb2xkZXIgKEVudGVy
  >> "!B64TMP!" echo ID0gZGVmYXVsdCksIGB5YCA9IGJ1aWxkIHJpZ2h0IGF3YXksCiAgIGB5YCA9IGNvbmZpcm0uIFVu
  >> "!B64TMP!" echo cGFja2luZyBydW5zIGBnZW5faW5zdGFsbGVycy5weWAgaW4gdGhlIHRhcmdldCBmb2xkZXIKICAg
  >> "!B64TMP!" echo d2hlbiB5b3UgYW5zd2VyZWQgYHlgLgoKMi4gKipSZWdlbmVyYXRlIGV2ZXJ5dGhpbmcqKiBpbnNp
  >> "!B64TMP!" echo ZGUgdGhlIHVucGFja2VkIGZvbGRlcjoKCiAgIGBgYHNoCiAgIHB5dGhvbiBnZW5faW5zdGFsbGVy
  >> "!B64TMP!" echo cy5weSAgICMgcmVidWlsZCBpbnN0YWxsLWxvY2FsLXNlYXJjaC5iYXQvLnNoCiAgIHB5dGhvbiBn
  >> "!B64TMP!" echo ZW5fcmlnLnB5ICAgICAgICAgICMgcmVidWlsZCB0aGUgdHdvIHBhY2tlcnMgYnl0ZS1mb3ItYnl0
  >> "!B64TMP!" echo ZQogICBgYGAKCiAgIEZyZXNoIGluc3RhbGxlcnMgYXJlIHdyaXR0ZW4gdG8gYDx0YXJnZXQ+XGxv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaFxgLCBhbmQgZnJlc2gKICAgcGFja2VycyByZXBsYWNlIHRoZSB1bnBhY2tlZCBg
  >> "!B64TMP!" echo bG9jYWwtc2VhcmNoLXJpZy4qYCBjb3BpZXMuIGBCVUlMRC5tZGAKICAgKGluc2lkZSB0aGUgdW5w
  >> "!B64TMP!" echo YWNrZWQgZm9sZGVyKSBkb2N1bWVudHMgdGhlIHRlc3Qgc2NyaXB0cwogICAoYHRlc3RfYjY0LnB5
  >> "!B64TMP!" echo YCwgYHRlc3RfcmlnLnB5YCwgYGUyZV90ZXN0LnNoYCwgLi4uKS4KCk5vdGU6IHRoZSBwYWNrZXJz
  >> "!B64TMP!" echo IGVtYmVkIHRoZSBzb3VyY2UgdHJlZSAqKmFzIG9mIHdoZW4gdGhleSB3ZXJlCmdlbmVyYXRlZCoq
  >> "!B64TMP!" echo LiBNYWtlIHNvdXJjZSBlZGl0cyBmaXJzdCwgb3IgY29weSB0aGUgZWRpdGVkIGZpbGVzIGludG8g
  >> "!B64TMP!" echo dGhlCnVucGFja2VkIGBsb2NhbC1zZWFyY2gvYCBmb2xkZXIsIGJlZm9yZSBydW5uaW5nIHRoZSBn
  >> "!B64TMP!" echo ZW5lcmF0b3JzLgoKIyMgU2VjdXJpdHkgbm90ZXMKCi0gVGhpcyBzdGFjayBpcyBkZXNpZ25lZCBm
  >> "!B64TMP!" echo b3IgKipsb2NhbCAvIHRydXN0ZWQtbmV0d29yayB1c2UqKi4gRmlyZWNyYXdsJ3MgQVBJIGlzCiAg
  >> "!B64TMP!" echo Kip1bmF1dGhlbnRpY2F0ZWQqKiAoYFVTRV9EQl9BVVRIRU5USUNBVElPTj1mYWxzZWApIHNvIHlv
  >> "!B64TMP!" echo dXIgbW9kZWxzIGNhbiBjYWxsIGl0CiAgd2l0aG91dCBhIGtleS4gKipEbyBub3QgZXhwb3NlIHBv
  >> "!B64TMP!" echo cnRzIDk5OTAvOTk5MSB0byB0aGUgcHVibGljIGludGVybmV0LioqCi0gQWxsIGNyZWRlbnRpYWxz
  >> "!B64TMP!" echo IChgU0VBUlhOR19TRUNSRVRgLCBgQlVMTF9BVVRIX0tFWWAsIGBQT1NUR1JFU19QQVNTV09SRGAs
  >> "!B64TMP!" echo CiAgYFJBQkJJVE1RX1BBU1NXT1JEYCwgYEJST1dTRVJMRVNTX1RPS0VOYCkgYXJlIGdlbmVyYXRl
  >> "!B64TMP!" echo ZCBhcyAyNTYtYml0IHJhbmRvbSBoZXgKICBhdCBpbnN0YWxsIHRpbWUgYW5kIHN0b3JlZCBvbmx5
  >> "!B64TMP!" echo IGluIHlvdXIgbG9jYWwgYC5lbnZgLgotIFNlYXJYTkcncyBib3QgbGltaXRlciBpcyBkaXNhYmxl
  >> "!B64TMP!" echo ZCBhbmQgSlNPTiBvdXRwdXQgaXMgZW5hYmxlZCBzbyBtb2RlbHMgY2FuCiAgcXVlcnkgaXQg4oCU
  >> "!B64TMP!" echo IHRoaXMgaXMgaW50ZW50aW9uYWwgZm9yIGxvY2FsIHVzZS4gT24gYSBwdWJsaWMgaW5zdGFuY2Ug
  >> "!B64TMP!" echo eW91J2Qgd2FudAogIHRoZSBsaW1pdGVyIGJhY2sgb24uCi0gWW91ciBzZWFyY2ggcXVlcmllcyBh
  >> "!B64TMP!" echo bmQgc2NyYXBlZCBwYWdlIGNvbnRlbnRzIG5ldmVyIGxlYXZlIHlvdXIgbWFjaGluZQogIChleGNl
  >> "!B64TMP!" echo cHQgdGhlIG91dGJvdW5kIGZldGNoZXMgU2VhclhORy9GaXJlY3Jhd2wgbWFrZSB0byB0aGUgcHVi
  >> "!B64TMP!" echo bGljIHdlYiwgd2hpY2gKICBpcyB0aGUgd2hvbGUgcG9pbnQpLgoKLS0tCgojIyBDcmVkaXRzICYg
  >> "!B64TMP!" echo bGljZW5zZXMKClRoaXMgcHJvamVjdCBpcyBsaWNlbnNlZCB1bmRlciB0aGUgKipNUEwtMi4wKiog
  >> "!B64TMP!" echo bGljZW5zZSDigJQgc2VlIFtMSUNFTlNFXShMSUNFTlNFKQooaXQgY292ZXJzIHRoZSBidW5kbGVk
  >> "!B64TMP!" echo IFtsb2NhbC13ZWItc2VhcmNoXShsb2NhbC13ZWItc2VhcmNoKSBza2lsbCB0b28pLgoKLSBbKipT
  >> "!B64TMP!" echo ZWFyWE5HKipdKGh0dHBzOi8vZ2l0aHViLmNvbS9zZWFyeG5nL3NlYXJ4bmcpIOKAlCBBR1BMLTMu
  >> "!B64TMP!" echo MCwgcHJpdmFjeS1yZXNwZWN0aW5nIG1ldGFzZWFyY2ggZW5naW5lLgotIFsqKkZpcmVjcmF3bCoq
  >> "!B64TMP!" echo XShodHRwczovL2dpdGh1Yi5jb20vZmlyZWNyYXdsL2ZpcmVjcmF3bCkg4oCUIEFHUEwtMy4wLCB0
  >> "!B64TMP!" echo aGUgY29udGV4dCBBUEkgZm9yIHdlYiBzY3JhcGluZy9jcmF3bGluZy9zZWFyY2guCi0gWyoqRmly
  >> "!B64TMP!" echo ZWNyYXdsIE1DUCBzZXJ2ZXIqKl0oaHR0cHM6Ly9naXRodWIuY29tL2ZpcmVjcmF3bC9maXJlY3Jh
  >> "!B64TMP!" echo d2wtbWNwLXNlcnZlcikg4oCUIE1JVC4KLSBUaGUgdXBzdHJlYW0gcHJvamVjdHMgcmV0YWluIHRo
  >> "!B64TMP!" echo ZWlyIG93biBsaWNlbnNlcyDigJQgcGxlYXNlIHJlc3BlY3QgdGhlbS4KICBOb3RoaW5nIGZyb20g
  >> "!B64TMP!" echo dGhlbSBpcyBidW5kbGVkIGluIHRoaXMgcmVwb3NpdG9yeTsgdGhlIGluc3RhbGxlciBvbmx5IHB1
  >> "!B64TMP!" echo bGxzCiAgdGhlaXIgb2ZmaWNpYWwgY29udGFpbmVyIGltYWdlcyBhdCBpbnN0YWxsIHRpbWUuCgot
  >> "!B64TMP!" echo LS0KCjxzdWI+QnVpbHQgc28gYW55IGxvY2FsIG1vZGVsIOKAlCBpbiBMTSBTdHVkaW8gb3Igb3Ro
  >> "!B64TMP!" echo ZXJ3aXNlIOKAlCBjYW4gc2VhcmNoIGFuZCByZWFkCnRoZSB3ZWIgd2l0aG91dCBhIHBhaWQgQVBJ
  >> "!B64TMP!" echo IGtleS4gQ29udHJpYnV0aW9ucyB3ZWxjb21lLjwvc3ViPgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\README.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- LICENSE ---
set "NEED_B64=1"
if exist "!SRC!\LICENSE" (
  copy /Y "!SRC!\LICENSE" "!TARGET!\LICENSE" >nul 2>&1
  if exist "!TARGET!\LICENSE" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] LICENSE  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1747782147.b64"
  > "!B64TMP!" echo TW96aWxsYSBQdWJsaWMgTGljZW5zZSBWZXJzaW9uIDIuMAo9PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09CgoxLiBEZWZpbml0aW9ucwotLS0tLS0tLS0tLS0tLQoKMS4xLiAiQ29udHJp
  >> "!B64TMP!" echo YnV0b3IiCiAgICBtZWFucyBlYWNoIGluZGl2aWR1YWwgb3IgbGVnYWwgZW50aXR5IHRoYXQgY3Jl
  >> "!B64TMP!" echo YXRlcywgY29udHJpYnV0ZXMgdG8KICAgIHRoZSBjcmVhdGlvbiBvZiwgb3Igb3ducyBDb3ZlcmVk
  >> "!B64TMP!" echo IFNvZnR3YXJlLgoKMS4yLiAiQ29udHJpYnV0b3IgVmVyc2lvbiIKICAgIG1lYW5zIHRoZSBjb21i
  >> "!B64TMP!" echo aW5hdGlvbiBvZiB0aGUgQ29udHJpYnV0aW9ucyBvZiBvdGhlcnMgKGlmIGFueSkgdXNlZAogICAg
  >> "!B64TMP!" echo YnkgYSBDb250cmlidXRvciBhbmQgdGhhdCBwYXJ0aWN1bGFyIENvbnRyaWJ1dG9yJ3MgQ29udHJp
  >> "!B64TMP!" echo YnV0aW9uLgoKMS4zLiAiQ29udHJpYnV0aW9uIgogICAgbWVhbnMgQ292ZXJlZCBTb2Z0d2FyZSBv
  >> "!B64TMP!" echo ZiBhIHBhcnRpY3VsYXIgQ29udHJpYnV0b3IuCgoxLjQuICJDb3ZlcmVkIFNvZnR3YXJlIgogICAg
  >> "!B64TMP!" echo bWVhbnMgU291cmNlIENvZGUgRm9ybSB0byB3aGljaCB0aGUgaW5pdGlhbCBDb250cmlidXRvciBo
  >> "!B64TMP!" echo YXMgYXR0YWNoZWQKICAgIHRoZSBub3RpY2UgaW4gRXhoaWJpdCBBLCB0aGUgRXhlY3V0YWJsZSBG
  >> "!B64TMP!" echo b3JtIG9mIHN1Y2ggU291cmNlIENvZGUKICAgIEZvcm0sIGFuZCBNb2RpZmljYXRpb25zIG9mIHN1
  >> "!B64TMP!" echo Y2ggU291cmNlIENvZGUgRm9ybSwgaW4gZWFjaCBjYXNlCiAgICBpbmNsdWRpbmcgcG9ydGlvbnMg
  >> "!B64TMP!" echo dGhlcmVvZi4KCjEuNS4gIkluY29tcGF0aWJsZSBXaXRoIFNlY29uZGFyeSBMaWNlbnNlcyIKICAg
  >> "!B64TMP!" echo IG1lYW5zCgogICAgKGEpIHRoYXQgdGhlIGluaXRpYWwgQ29udHJpYnV0b3IgaGFzIGF0dGFjaGVk
  >> "!B64TMP!" echo IHRoZSBub3RpY2UgZGVzY3JpYmVkCiAgICAgICAgaW4gRXhoaWJpdCBCIHRvIHRoZSBDb3ZlcmVk
  >> "!B64TMP!" echo IFNvZnR3YXJlOyBvcgoKICAgIChiKSB0aGF0IHRoZSBDb3ZlcmVkIFNvZnR3YXJlIHdhcyBtYWRl
  >> "!B64TMP!" echo IGF2YWlsYWJsZSB1bmRlciB0aGUgdGVybXMgb2YKICAgICAgICB2ZXJzaW9uIDEuMSBvciBlYXJs
  >> "!B64TMP!" echo aWVyIG9mIHRoZSBMaWNlbnNlLCBidXQgbm90IGFsc28gdW5kZXIgdGhlCiAgICAgICAgdGVybXMg
  >> "!B64TMP!" echo b2YgYSBTZWNvbmRhcnkgTGljZW5zZS4KCjEuNi4gIkV4ZWN1dGFibGUgRm9ybSIKICAgIG1lYW5z
  >> "!B64TMP!" echo IGFueSBmb3JtIG9mIHRoZSB3b3JrIG90aGVyIHRoYW4gU291cmNlIENvZGUgRm9ybS4KCjEuNy4g
  >> "!B64TMP!" echo IkxhcmdlciBXb3JrIgogICAgbWVhbnMgYSB3b3JrIHRoYXQgY29tYmluZXMgQ292ZXJlZCBTb2Z0
  >> "!B64TMP!" echo d2FyZSB3aXRoIG90aGVyIG1hdGVyaWFsLCBpbgogICAgYSBzZXBhcmF0ZSBmaWxlIG9yIGZpbGVz
  >> "!B64TMP!" echo LCB0aGF0IGlzIG5vdCBDb3ZlcmVkIFNvZnR3YXJlLgoKMS44LiAiTGljZW5zZSIKICAgIG1lYW5z
  >> "!B64TMP!" echo IHRoaXMgZG9jdW1lbnQuCgoxLjkuICJMaWNlbnNhYmxlIgogICAgbWVhbnMgaGF2aW5nIHRoZSBy
  >> "!B64TMP!" echo aWdodCB0byBncmFudCwgdG8gdGhlIG1heGltdW0gZXh0ZW50IHBvc3NpYmxlLAogICAgd2hldGhl
  >> "!B64TMP!" echo ciBhdCB0aGUgdGltZSBvZiB0aGUgaW5pdGlhbCBncmFudCBvciBzdWJzZXF1ZW50bHksIGFueSBh
  >> "!B64TMP!" echo bmQKICAgIGFsbCBvZiB0aGUgcmlnaHRzIGNvbnZleWVkIGJ5IHRoaXMgTGljZW5zZS4KCjEuMTAu
  >> "!B64TMP!" echo ICJNb2RpZmljYXRpb25zIgogICAgbWVhbnMgYW55IG9mIHRoZSBmb2xsb3dpbmc6CgogICAgKGEp
  >> "!B64TMP!" echo IGFueSBmaWxlIGluIFNvdXJjZSBDb2RlIEZvcm0gdGhhdCByZXN1bHRzIGZyb20gYW4gYWRkaXRp
  >> "!B64TMP!" echo b24gdG8sCiAgICAgICAgZGVsZXRpb24gZnJvbSwgb3IgbW9kaWZpY2F0aW9uIG9mIHRoZSBjb250
  >> "!B64TMP!" echo ZW50cyBvZiBDb3ZlcmVkCiAgICAgICAgU29mdHdhcmU7IG9yCgogICAgKGIpIGFueSBuZXcgZmls
  >> "!B64TMP!" echo ZSBpbiBTb3VyY2UgQ29kZSBGb3JtIHRoYXQgY29udGFpbnMgYW55IENvdmVyZWQKICAgICAgICBT
  >> "!B64TMP!" echo b2Z0d2FyZS4KCjEuMTEuICJQYXRlbnQgQ2xhaW1zIiBvZiBhIENvbnRyaWJ1dG9yCiAgICBtZWFu
  >> "!B64TMP!" echo cyBhbnkgcGF0ZW50IGNsYWltKHMpLCBpbmNsdWRpbmcgd2l0aG91dCBsaW1pdGF0aW9uLCBtZXRo
  >> "!B64TMP!" echo b2QsCiAgICBwcm9jZXNzLCBhbmQgYXBwYXJhdHVzIGNsYWltcywgaW4gYW55IHBhdGVudCBMaWNl
  >> "!B64TMP!" echo bnNhYmxlIGJ5IHN1Y2gKICAgIENvbnRyaWJ1dG9yIHRoYXQgd291bGQgYmUgaW5mcmluZ2VkLCBi
  >> "!B64TMP!" echo dXQgZm9yIHRoZSBncmFudCBvZiB0aGUKICAgIExpY2Vuc2UsIGJ5IHRoZSBtYWtpbmcsIHVzaW5n
  >> "!B64TMP!" echo LCBzZWxsaW5nLCBvZmZlcmluZyBmb3Igc2FsZSwgaGF2aW5nCiAgICBtYWRlLCBpbXBvcnQsIG9y
  >> "!B64TMP!" echo IHRyYW5zZmVyIG9mIGVpdGhlciBpdHMgQ29udHJpYnV0aW9ucyBvciBpdHMKICAgIENvbnRyaWJ1
  >> "!B64TMP!" echo dG9yIFZlcnNpb24uCgoxLjEyLiAiU2Vjb25kYXJ5IExpY2Vuc2UiCiAgICBtZWFucyBlaXRoZXIg
  >> "!B64TMP!" echo dGhlIEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlLCBWZXJzaW9uIDIuMCwgdGhlIEdOVQogICAg
  >> "!B64TMP!" echo TGVzc2VyIEdlbmVyYWwgUHVibGljIExpY2Vuc2UsIFZlcnNpb24gMi4xLCB0aGUgR05VIEFmZmVy
  >> "!B64TMP!" echo byBHZW5lcmFsCiAgICBQdWJsaWMgTGljZW5zZSwgVmVyc2lvbiAzLjAsIG9yIGFueSBsYXRlciB2
  >> "!B64TMP!" echo ZXJzaW9ucyBvZiB0aG9zZQogICAgbGljZW5zZXMuCgoxLjEzLiAiU291cmNlIENvZGUgRm9ybSIK
  >> "!B64TMP!" echo ICAgIG1lYW5zIHRoZSBmb3JtIG9mIHRoZSB3b3JrIHByZWZlcnJlZCBmb3IgbWFraW5nIG1vZGlm
  >> "!B64TMP!" echo aWNhdGlvbnMuCgoxLjE0LiAiWW91IiAob3IgIllvdXIiKQogICAgbWVhbnMgYW4gaW5kaXZpZHVh
  >> "!B64TMP!" echo bCBvciBhIGxlZ2FsIGVudGl0eSBleGVyY2lzaW5nIHJpZ2h0cyB1bmRlciB0aGlzCiAgICBMaWNl
  >> "!B64TMP!" echo bnNlLiBGb3IgbGVnYWwgZW50aXRpZXMsICJZb3UiIGluY2x1ZGVzIGFueSBlbnRpdHkgdGhhdAog
  >> "!B64TMP!" echo ICAgY29udHJvbHMsIGlzIGNvbnRyb2xsZWQgYnksIG9yIGlzIHVuZGVyIGNvbW1vbiBjb250cm9s
  >> "!B64TMP!" echo IHdpdGggWW91LiBGb3IKICAgIHB1cnBvc2VzIG9mIHRoaXMgZGVmaW5pdGlvbiwgImNvbnRyb2wi
  >> "!B64TMP!" echo IG1lYW5zIChhKSB0aGUgcG93ZXIsIGRpcmVjdAogICAgb3IgaW5kaXJlY3QsIHRvIGNhdXNlIHRo
  >> "!B64TMP!" echo ZSBkaXJlY3Rpb24gb3IgbWFuYWdlbWVudCBvZiBzdWNoIGVudGl0eSwKICAgIHdoZXRoZXIgYnkg
  >> "!B64TMP!" echo Y29udHJhY3Qgb3Igb3RoZXJ3aXNlLCBvciAoYikgb3duZXJzaGlwIG9mIG1vcmUgdGhhbgogICAg
  >> "!B64TMP!" echo ZmlmdHkgcGVyY2VudCAoNTAlKSBvZiB0aGUgb3V0c3RhbmRpbmcgc2hhcmVzIG9yIGJlbmVmaWNp
  >> "!B64TMP!" echo YWwKICAgIG93bmVyc2hpcCBvZiBzdWNoIGVudGl0eS4KCjIuIExpY2Vuc2UgR3JhbnRzIGFuZCBD
  >> "!B64TMP!" echo b25kaXRpb25zCi0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgoyLjEuIEdyYW50cwoK
  >> "!B64TMP!" echo RWFjaCBDb250cmlidXRvciBoZXJlYnkgZ3JhbnRzIFlvdSBhIHdvcmxkLXdpZGUsIHJveWFsdHkt
  >> "!B64TMP!" echo ZnJlZSwKbm9uLWV4Y2x1c2l2ZSBsaWNlbnNlOgoKKGEpIHVuZGVyIGludGVsbGVjdHVhbCBwcm9w
  >> "!B64TMP!" echo ZXJ0eSByaWdodHMgKG90aGVyIHRoYW4gcGF0ZW50IG9yIHRyYWRlbWFyaykKICAgIExpY2Vuc2Fi
  >> "!B64TMP!" echo bGUgYnkgc3VjaCBDb250cmlidXRvciB0byB1c2UsIHJlcHJvZHVjZSwgbWFrZSBhdmFpbGFibGUs
  >> "!B64TMP!" echo CiAgICBtb2RpZnksIGRpc3BsYXksIHBlcmZvcm0sIGRpc3RyaWJ1dGUsIGFuZCBvdGhlcndpc2Ug
  >> "!B64TMP!" echo ZXhwbG9pdCBpdHMKICAgIENvbnRyaWJ1dGlvbnMsIGVpdGhlciBvbiBhbiB1bm1vZGlmaWVkIGJh
  >> "!B64TMP!" echo c2lzLCB3aXRoIE1vZGlmaWNhdGlvbnMsIG9yCiAgICBhcyBwYXJ0IG9mIGEgTGFyZ2VyIFdvcms7
  >> "!B64TMP!" echo IGFuZAoKKGIpIHVuZGVyIFBhdGVudCBDbGFpbXMgb2Ygc3VjaCBDb250cmlidXRvciB0byBtYWtl
  >> "!B64TMP!" echo LCB1c2UsIHNlbGwsIG9mZmVyCiAgICBmb3Igc2FsZSwgaGF2ZSBtYWRlLCBpbXBvcnQsIGFuZCBv
  >> "!B64TMP!" echo dGhlcndpc2UgdHJhbnNmZXIgZWl0aGVyIGl0cwogICAgQ29udHJpYnV0aW9ucyBvciBpdHMgQ29u
  >> "!B64TMP!" echo dHJpYnV0b3IgVmVyc2lvbi4KCjIuMi4gRWZmZWN0aXZlIERhdGUKClRoZSBsaWNlbnNlcyBncmFu
  >> "!B64TMP!" echo dGVkIGluIFNlY3Rpb24gMi4xIHdpdGggcmVzcGVjdCB0byBhbnkgQ29udHJpYnV0aW9uCmJlY29t
  >> "!B64TMP!" echo ZSBlZmZlY3RpdmUgZm9yIGVhY2ggQ29udHJpYnV0aW9uIG9uIHRoZSBkYXRlIHRoZSBDb250cmli
  >> "!B64TMP!" echo dXRvciBmaXJzdApkaXN0cmlidXRlcyBzdWNoIENvbnRyaWJ1dGlvbi4KCjIuMy4gTGltaXRhdGlv
  >> "!B64TMP!" echo bnMgb24gR3JhbnQgU2NvcGUKClRoZSBsaWNlbnNlcyBncmFudGVkIGluIHRoaXMgU2VjdGlvbiAy
  >> "!B64TMP!" echo IGFyZSB0aGUgb25seSByaWdodHMgZ3JhbnRlZCB1bmRlcgp0aGlzIExpY2Vuc2UuIE5vIGFkZGl0
  >> "!B64TMP!" echo aW9uYWwgcmlnaHRzIG9yIGxpY2Vuc2VzIHdpbGwgYmUgaW1wbGllZCBmcm9tIHRoZQpkaXN0cmli
  >> "!B64TMP!" echo dXRpb24gb3IgbGljZW5zaW5nIG9mIENvdmVyZWQgU29mdHdhcmUgdW5kZXIgdGhpcyBMaWNlbnNl
  >> "!B64TMP!" echo LgpOb3R3aXRoc3RhbmRpbmcgU2VjdGlvbiAyLjEoYikgYWJvdmUsIG5vIHBhdGVudCBsaWNlbnNl
  >> "!B64TMP!" echo IGlzIGdyYW50ZWQgYnkgYQpDb250cmlidXRvcjoKCihhKSBmb3IgYW55IGNvZGUgdGhhdCBhIENv
  >> "!B64TMP!" echo bnRyaWJ1dG9yIGhhcyByZW1vdmVkIGZyb20gQ292ZXJlZCBTb2Z0d2FyZTsKICAgIG9yCgooYikg
  >> "!B64TMP!" echo Zm9yIGluZnJpbmdlbWVudHMgY2F1c2VkIGJ5OiAoaSkgWW91ciBhbmQgYW55IG90aGVyIHRoaXJk
  >> "!B64TMP!" echo IHBhcnR5J3MKICAgIG1vZGlmaWNhdGlvbnMgb2YgQ292ZXJlZCBTb2Z0d2FyZSwgb3IgKGlpKSB0
  >> "!B64TMP!" echo aGUgY29tYmluYXRpb24gb2YgaXRzCiAgICBDb250cmlidXRpb25zIHdpdGggb3RoZXIgc29mdHdh
  >> "!B64TMP!" echo cmUgKGV4Y2VwdCBhcyBwYXJ0IG9mIGl0cyBDb250cmlidXRvcgogICAgVmVyc2lvbik7IG9yCgoo
  >> "!B64TMP!" echo YykgdW5kZXIgUGF0ZW50IENsYWltcyBpbmZyaW5nZWQgYnkgQ292ZXJlZCBTb2Z0d2FyZSBpbiB0
  >> "!B64TMP!" echo aGUgYWJzZW5jZSBvZgogICAgaXRzIENvbnRyaWJ1dGlvbnMuCgpUaGlzIExpY2Vuc2UgZG9lcyBu
  >> "!B64TMP!" echo b3QgZ3JhbnQgYW55IHJpZ2h0cyBpbiB0aGUgdHJhZGVtYXJrcywgc2VydmljZSBtYXJrcywKb3Ig
  >> "!B64TMP!" echo bG9nb3Mgb2YgYW55IENvbnRyaWJ1dG9yIChleGNlcHQgYXMgbWF5IGJlIG5lY2Vzc2FyeSB0byBj
  >> "!B64TMP!" echo b21wbHkgd2l0aAp0aGUgbm90aWNlIHJlcXVpcmVtZW50cyBpbiBTZWN0aW9uIDMuNCkuCgoyLjQu
  >> "!B64TMP!" echo IFN1YnNlcXVlbnQgTGljZW5zZXMKCk5vIENvbnRyaWJ1dG9yIG1ha2VzIGFkZGl0aW9uYWwgZ3Jh
  >> "!B64TMP!" echo bnRzIGFzIGEgcmVzdWx0IG9mIFlvdXIgY2hvaWNlIHRvCmRpc3RyaWJ1dGUgdGhlIENvdmVyZWQg
  >> "!B64TMP!" echo U29mdHdhcmUgdW5kZXIgYSBzdWJzZXF1ZW50IHZlcnNpb24gb2YgdGhpcwpMaWNlbnNlIChzZWUg
  >> "!B64TMP!" echo U2VjdGlvbiAxMC4yKSBvciB1bmRlciB0aGUgdGVybXMgb2YgYSBTZWNvbmRhcnkgTGljZW5zZSAo
  >> "!B64TMP!" echo aWYKcGVybWl0dGVkIHVuZGVyIHRoZSB0ZXJtcyBvZiBTZWN0aW9uIDMuMykuCgoyLjUuIFJlcHJl
  >> "!B64TMP!" echo c2VudGF0aW9uCgpFYWNoIENvbnRyaWJ1dG9yIHJlcHJlc2VudHMgdGhhdCB0aGUgQ29udHJpYnV0
  >> "!B64TMP!" echo b3IgYmVsaWV2ZXMgaXRzCkNvbnRyaWJ1dGlvbnMgYXJlIGl0cyBvcmlnaW5hbCBjcmVhdGlvbihz
  >> "!B64TMP!" echo KSBvciBpdCBoYXMgc3VmZmljaWVudCByaWdodHMKdG8gZ3JhbnQgdGhlIHJpZ2h0cyB0byBpdHMg
  >> "!B64TMP!" echo Q29udHJpYnV0aW9ucyBjb252ZXllZCBieSB0aGlzIExpY2Vuc2UuCgoyLjYuIEZhaXIgVXNlCgpU
  >> "!B64TMP!" echo aGlzIExpY2Vuc2UgaXMgbm90IGludGVuZGVkIHRvIGxpbWl0IGFueSByaWdodHMgWW91IGhhdmUg
  >> "!B64TMP!" echo dW5kZXIKYXBwbGljYWJsZSBjb3B5cmlnaHQgZG9jdHJpbmVzIG9mIGZhaXIgdXNlLCBmYWlyIGRl
  >> "!B64TMP!" echo YWxpbmcsIG9yIG90aGVyCmVxdWl2YWxlbnRzLgoKMi43LiBDb25kaXRpb25zCgpTZWN0aW9ucyAz
  >> "!B64TMP!" echo LjEsIDMuMiwgMy4zLCBhbmQgMy40IGFyZSBjb25kaXRpb25zIG9mIHRoZSBsaWNlbnNlcyBncmFu
  >> "!B64TMP!" echo dGVkCmluIFNlY3Rpb24gMi4xLgoKMy4gUmVzcG9uc2liaWxpdGllcwotLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tCgozLjEuIERpc3RyaWJ1dGlvbiBvZiBTb3VyY2UgRm9ybQoKQWxsIGRpc3RyaWJ1dGlvbiBv
  >> "!B64TMP!" echo ZiBDb3ZlcmVkIFNvZnR3YXJlIGluIFNvdXJjZSBDb2RlIEZvcm0sIGluY2x1ZGluZyBhbnkKTW9k
  >> "!B64TMP!" echo aWZpY2F0aW9ucyB0aGF0IFlvdSBjcmVhdGUgb3IgdG8gd2hpY2ggWW91IGNvbnRyaWJ1dGUsIG11
  >> "!B64TMP!" echo c3QgYmUgdW5kZXIKdGhlIHRlcm1zIG9mIHRoaXMgTGljZW5zZS4gWW91IG11c3QgaW5mb3JtIHJl
  >> "!B64TMP!" echo Y2lwaWVudHMgdGhhdCB0aGUgU291cmNlCkNvZGUgRm9ybSBvZiB0aGUgQ292ZXJlZCBTb2Z0d2Fy
  >> "!B64TMP!" echo ZSBpcyBnb3Zlcm5lZCBieSB0aGUgdGVybXMgb2YgdGhpcwpMaWNlbnNlLCBhbmQgaG93IHRoZXkg
  >> "!B64TMP!" echo Y2FuIG9idGFpbiBhIGNvcHkgb2YgdGhpcyBMaWNlbnNlLiBZb3UgbWF5IG5vdAphdHRlbXB0IHRv
  >> "!B64TMP!" echo IGFsdGVyIG9yIHJlc3RyaWN0IHRoZSByZWNpcGllbnRzJyByaWdodHMgaW4gdGhlIFNvdXJjZSBD
  >> "!B64TMP!" echo b2RlCkZvcm0uCgozLjIuIERpc3RyaWJ1dGlvbiBvZiBFeGVjdXRhYmxlIEZvcm0KCklmIFlvdSBk
  >> "!B64TMP!" echo aXN0cmlidXRlIENvdmVyZWQgU29mdHdhcmUgaW4gRXhlY3V0YWJsZSBGb3JtIHRoZW46CgooYSkg
  >> "!B64TMP!" echo c3VjaCBDb3ZlcmVkIFNvZnR3YXJlIG11c3QgYWxzbyBiZSBtYWRlIGF2YWlsYWJsZSBpbiBTb3Vy
  >> "!B64TMP!" echo Y2UgQ29kZQogICAgRm9ybSwgYXMgZGVzY3JpYmVkIGluIFNlY3Rpb24gMy4xLCBhbmQgWW91IG11
  >> "!B64TMP!" echo c3QgaW5mb3JtIHJlY2lwaWVudHMgb2YKICAgIHRoZSBFeGVjdXRhYmxlIEZvcm0gaG93IHRoZXkg
  >> "!B64TMP!" echo Y2FuIG9idGFpbiBhIGNvcHkgb2Ygc3VjaCBTb3VyY2UgQ29kZQogICAgRm9ybSBieSByZWFzb25h
  >> "!B64TMP!" echo YmxlIG1lYW5zIGluIGEgdGltZWx5IG1hbm5lciwgYXQgYSBjaGFyZ2Ugbm8gbW9yZQogICAgdGhh
  >> "!B64TMP!" echo biB0aGUgY29zdCBvZiBkaXN0cmlidXRpb24gdG8gdGhlIHJlY2lwaWVudDsgYW5kCgooYikgWW91
  >> "!B64TMP!" echo IG1heSBkaXN0cmlidXRlIHN1Y2ggRXhlY3V0YWJsZSBGb3JtIHVuZGVyIHRoZSB0ZXJtcyBvZiB0
  >> "!B64TMP!" echo aGlzCiAgICBMaWNlbnNlLCBvciBzdWJsaWNlbnNlIGl0IHVuZGVyIGRpZmZlcmVudCB0ZXJtcywg
  >> "!B64TMP!" echo cHJvdmlkZWQgdGhhdCB0aGUKICAgIGxpY2Vuc2UgZm9yIHRoZSBFeGVjdXRhYmxlIEZvcm0gZG9l
  >> "!B64TMP!" echo cyBub3QgYXR0ZW1wdCB0byBsaW1pdCBvciBhbHRlcgogICAgdGhlIHJlY2lwaWVudHMnIHJpZ2h0
  >> "!B64TMP!" echo cyBpbiB0aGUgU291cmNlIENvZGUgRm9ybSB1bmRlciB0aGlzIExpY2Vuc2UuCgozLjMuIERpc3Ry
  >> "!B64TMP!" echo aWJ1dGlvbiBvZiBhIExhcmdlciBXb3JrCgpZb3UgbWF5IGNyZWF0ZSBhbmQgZGlzdHJpYnV0ZSBh
  >> "!B64TMP!" echo IExhcmdlciBXb3JrIHVuZGVyIHRlcm1zIG9mIFlvdXIgY2hvaWNlLApwcm92aWRlZCB0aGF0IFlv
  >> "!B64TMP!" echo dSBhbHNvIGNvbXBseSB3aXRoIHRoZSByZXF1aXJlbWVudHMgb2YgdGhpcyBMaWNlbnNlIGZvcgp0
  >> "!B64TMP!" echo aGUgQ292ZXJlZCBTb2Z0d2FyZS4gSWYgdGhlIExhcmdlciBXb3JrIGlzIGEgY29tYmluYXRpb24g
  >> "!B64TMP!" echo b2YgQ292ZXJlZApTb2Z0d2FyZSB3aXRoIGEgd29yayBnb3Zlcm5lZCBieSBvbmUgb3IgbW9yZSBT
  >> "!B64TMP!" echo ZWNvbmRhcnkgTGljZW5zZXMsIGFuZCB0aGUKQ292ZXJlZCBTb2Z0d2FyZSBpcyBub3QgSW5jb21w
  >> "!B64TMP!" echo YXRpYmxlIFdpdGggU2Vjb25kYXJ5IExpY2Vuc2VzLCB0aGlzCkxpY2Vuc2UgcGVybWl0cyBZb3Ug
  >> "!B64TMP!" echo dG8gYWRkaXRpb25hbGx5IGRpc3RyaWJ1dGUgc3VjaCBDb3ZlcmVkIFNvZnR3YXJlCnVuZGVyIHRo
  >> "!B64TMP!" echo ZSB0ZXJtcyBvZiBzdWNoIFNlY29uZGFyeSBMaWNlbnNlKHMpLCBzbyB0aGF0IHRoZSByZWNpcGll
  >> "!B64TMP!" echo bnQgb2YKdGhlIExhcmdlciBXb3JrIG1heSwgYXQgdGhlaXIgb3B0aW9uLCBmdXJ0aGVyIGRpc3Ry
  >> "!B64TMP!" echo aWJ1dGUgdGhlIENvdmVyZWQKU29mdHdhcmUgdW5kZXIgdGhlIHRlcm1zIG9mIGVpdGhlciB0aGlz
  >> "!B64TMP!" echo IExpY2Vuc2Ugb3Igc3VjaCBTZWNvbmRhcnkKTGljZW5zZShzKS4KCjMuNC4gTm90aWNlcwoKWW91
  >> "!B64TMP!" echo IG1heSBub3QgcmVtb3ZlIG9yIGFsdGVyIHRoZSBzdWJzdGFuY2Ugb2YgYW55IGxpY2Vuc2Ugbm90
  >> "!B64TMP!" echo aWNlcwooaW5jbHVkaW5nIGNvcHlyaWdodCBub3RpY2VzLCBwYXRlbnQgbm90aWNlcywgZGlzY2xh
  >> "!B64TMP!" echo aW1lcnMgb2Ygd2FycmFudHksCm9yIGxpbWl0YXRpb25zIG9mIGxpYWJpbGl0eSkgY29udGFpbmVk
  >> "!B64TMP!" echo IHdpdGhpbiB0aGUgU291cmNlIENvZGUgRm9ybSBvZgp0aGUgQ292ZXJlZCBTb2Z0d2FyZSwgZXhj
  >> "!B64TMP!" echo ZXB0IHRoYXQgWW91IG1heSBhbHRlciBhbnkgbGljZW5zZSBub3RpY2VzIHRvCnRoZSBleHRlbnQg
  >> "!B64TMP!" echo cmVxdWlyZWQgdG8gcmVtZWR5IGtub3duIGZhY3R1YWwgaW5hY2N1cmFjaWVzLgoKMy41LiBBcHBs
  >> "!B64TMP!" echo aWNhdGlvbiBvZiBBZGRpdGlvbmFsIFRlcm1zCgpZb3UgbWF5IGNob29zZSB0byBvZmZlciwgYW5k
  >> "!B64TMP!" echo IHRvIGNoYXJnZSBhIGZlZSBmb3IsIHdhcnJhbnR5LCBzdXBwb3J0LAppbmRlbW5pdHkgb3IgbGlh
  >> "!B64TMP!" echo YmlsaXR5IG9ibGlnYXRpb25zIHRvIG9uZSBvciBtb3JlIHJlY2lwaWVudHMgb2YgQ292ZXJlZApT
  >> "!B64TMP!" echo b2Z0d2FyZS4gSG93ZXZlciwgWW91IG1heSBkbyBzbyBvbmx5IG9uIFlvdXIgb3duIGJlaGFsZiwg
  >> "!B64TMP!" echo YW5kIG5vdCBvbgpiZWhhbGYgb2YgYW55IENvbnRyaWJ1dG9yLiBZb3UgbXVzdCBtYWtlIGl0IGFi
  >> "!B64TMP!" echo c29sdXRlbHkgY2xlYXIgdGhhdCBhbnkKc3VjaCB3YXJyYW50eSwgc3VwcG9ydCwgaW5kZW1uaXR5
  >> "!B64TMP!" echo LCBvciBsaWFiaWxpdHkgb2JsaWdhdGlvbiBpcyBvZmZlcmVkIGJ5CllvdSBhbG9uZSwgYW5kIFlv
  >> "!B64TMP!" echo dSBoZXJlYnkgYWdyZWUgdG8gaW5kZW1uaWZ5IGV2ZXJ5IENvbnRyaWJ1dG9yIGZvciBhbnkKbGlh
  >> "!B64TMP!" echo YmlsaXR5IGluY3VycmVkIGJ5IHN1Y2ggQ29udHJpYnV0b3IgYXMgYSByZXN1bHQgb2Ygd2FycmFu
  >> "!B64TMP!" echo dHksIHN1cHBvcnQsCmluZGVtbml0eSBvciBsaWFiaWxpdHkgdGVybXMgWW91IG9mZmVyLiBZb3Ug
  >> "!B64TMP!" echo bWF5IGluY2x1ZGUgYWRkaXRpb25hbApkaXNjbGFpbWVycyBvZiB3YXJyYW50eSBhbmQgbGltaXRh
  >> "!B64TMP!" echo dGlvbnMgb2YgbGlhYmlsaXR5IHNwZWNpZmljIHRvIGFueQpqdXJpc2RpY3Rpb24uCgo0LiBJbmFi
  >> "!B64TMP!" echo aWxpdHkgdG8gQ29tcGx5IER1ZSB0byBTdGF0dXRlIG9yIFJlZ3VsYXRpb24KLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgpJZiBpdCBpcyBpbXBvc3Np
  >> "!B64TMP!" echo YmxlIGZvciBZb3UgdG8gY29tcGx5IHdpdGggYW55IG9mIHRoZSB0ZXJtcyBvZiB0aGlzCkxpY2Vu
  >> "!B64TMP!" echo c2Ugd2l0aCByZXNwZWN0IHRvIHNvbWUgb3IgYWxsIG9mIHRoZSBDb3ZlcmVkIFNvZnR3YXJlIGR1
  >> "!B64TMP!" echo ZSB0bwpzdGF0dXRlLCBqdWRpY2lhbCBvcmRlciwgb3IgcmVndWxhdGlvbiB0aGVuIFlvdSBtdXN0
  >> "!B64TMP!" echo OiAoYSkgY29tcGx5IHdpdGgKdGhlIHRlcm1zIG9mIHRoaXMgTGljZW5zZSB0byB0aGUgbWF4aW11
  >> "!B64TMP!" echo bSBleHRlbnQgcG9zc2libGU7IGFuZCAoYikKZGVzY3JpYmUgdGhlIGxpbWl0YXRpb25zIGFuZCB0
  >> "!B64TMP!" echo aGUgY29kZSB0aGV5IGFmZmVjdC4gU3VjaCBkZXNjcmlwdGlvbiBtdXN0CmJlIHBsYWNlZCBpbiBh
  >> "!B64TMP!" echo IHRleHQgZmlsZSBpbmNsdWRlZCB3aXRoIGFsbCBkaXN0cmlidXRpb25zIG9mIHRoZSBDb3ZlcmVk
  >> "!B64TMP!" echo ClNvZnR3YXJlIHVuZGVyIHRoaXMgTGljZW5zZS4gRXhjZXB0IHRvIHRoZSBleHRlbnQgcHJvaGli
  >> "!B64TMP!" echo aXRlZCBieSBzdGF0dXRlCm9yIHJlZ3VsYXRpb24sIHN1Y2ggZGVzY3JpcHRpb24gbXVzdCBiZSBz
  >> "!B64TMP!" echo dWZmaWNpZW50bHkgZGV0YWlsZWQgZm9yIGEKcmVjaXBpZW50IG9mIG9yZGluYXJ5IHNraWxsIHRv
  >> "!B64TMP!" echo IGJlIGFibGUgdG8gdW5kZXJzdGFuZCBpdC4KCjUuIFRlcm1pbmF0aW9uCi0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo Cgo1LjEuIFRoZSByaWdodHMgZ3JhbnRlZCB1bmRlciB0aGlzIExpY2Vuc2Ugd2lsbCB0ZXJtaW5h
  >> "!B64TMP!" echo dGUgYXV0b21hdGljYWxseQppZiBZb3UgZmFpbCB0byBjb21wbHkgd2l0aCBhbnkgb2YgaXRzIHRl
  >> "!B64TMP!" echo cm1zLiBIb3dldmVyLCBpZiBZb3UgYmVjb21lCmNvbXBsaWFudCwgdGhlbiB0aGUgcmlnaHRzIGdy
  >> "!B64TMP!" echo YW50ZWQgdW5kZXIgdGhpcyBMaWNlbnNlIGZyb20gYSBwYXJ0aWN1bGFyCkNvbnRyaWJ1dG9yIGFy
  >> "!B64TMP!" echo ZSByZWluc3RhdGVkIChhKSBwcm92aXNpb25hbGx5LCB1bmxlc3MgYW5kIHVudGlsIHN1Y2gKQ29u
  >> "!B64TMP!" echo dHJpYnV0b3IgZXhwbGljaXRseSBhbmQgZmluYWxseSB0ZXJtaW5hdGVzIFlvdXIgZ3JhbnRzLCBh
  >> "!B64TMP!" echo bmQgKGIpIG9uIGFuCm9uZ29pbmcgYmFzaXMsIGlmIHN1Y2ggQ29udHJpYnV0b3IgZmFpbHMgdG8g
  >> "!B64TMP!" echo bm90aWZ5IFlvdSBvZiB0aGUKbm9uLWNvbXBsaWFuY2UgYnkgc29tZSByZWFzb25hYmxlIG1lYW5z
  >> "!B64TMP!" echo IHByaW9yIHRvIDYwIGRheXMgYWZ0ZXIgWW91IGhhdmUKY29tZSBiYWNrIGludG8gY29tcGxpYW5j
  >> "!B64TMP!" echo ZS4gTW9yZW92ZXIsIFlvdXIgZ3JhbnRzIGZyb20gYSBwYXJ0aWN1bGFyCkNvbnRyaWJ1dG9yIGFy
  >> "!B64TMP!" echo ZSByZWluc3RhdGVkIG9uIGFuIG9uZ29pbmcgYmFzaXMgaWYgc3VjaCBDb250cmlidXRvcgpub3Rp
  >> "!B64TMP!" echo ZmllcyBZb3Ugb2YgdGhlIG5vbi1jb21wbGlhbmNlIGJ5IHNvbWUgcmVhc29uYWJsZSBtZWFucywg
  >> "!B64TMP!" echo dGhpcyBpcyB0aGUKZmlyc3QgdGltZSBZb3UgaGF2ZSByZWNlaXZlZCBub3RpY2Ugb2Ygbm9uLWNv
  >> "!B64TMP!" echo bXBsaWFuY2Ugd2l0aCB0aGlzIExpY2Vuc2UKZnJvbSBzdWNoIENvbnRyaWJ1dG9yLCBhbmQgWW91
  >> "!B64TMP!" echo IGJlY29tZSBjb21wbGlhbnQgcHJpb3IgdG8gMzAgZGF5cyBhZnRlcgpZb3VyIHJlY2VpcHQgb2Yg
  >> "!B64TMP!" echo dGhlIG5vdGljZS4KCjUuMi4gSWYgWW91IGluaXRpYXRlIGxpdGlnYXRpb24gYWdhaW5zdCBhbnkg
  >> "!B64TMP!" echo ZW50aXR5IGJ5IGFzc2VydGluZyBhIHBhdGVudAppbmZyaW5nZW1lbnQgY2xhaW0gKGV4Y2x1ZGlu
  >> "!B64TMP!" echo ZyBkZWNsYXJhdG9yeSBqdWRnbWVudCBhY3Rpb25zLApjb3VudGVyLWNsYWltcywgYW5kIGNyb3Nz
  >> "!B64TMP!" echo LWNsYWltcykgYWxsZWdpbmcgdGhhdCBhIENvbnRyaWJ1dG9yIFZlcnNpb24KZGlyZWN0bHkgb3Ig
  >> "!B64TMP!" echo aW5kaXJlY3RseSBpbmZyaW5nZXMgYW55IHBhdGVudCwgdGhlbiB0aGUgcmlnaHRzIGdyYW50ZWQg
  >> "!B64TMP!" echo dG8KWW91IGJ5IGFueSBhbmQgYWxsIENvbnRyaWJ1dG9ycyBmb3IgdGhlIENvdmVyZWQgU29mdHdh
  >> "!B64TMP!" echo cmUgdW5kZXIgU2VjdGlvbgoyLjEgb2YgdGhpcyBMaWNlbnNlIHNoYWxsIHRlcm1pbmF0ZS4KCjUu
  >> "!B64TMP!" echo My4gSW4gdGhlIGV2ZW50IG9mIHRlcm1pbmF0aW9uIHVuZGVyIFNlY3Rpb25zIDUuMSBvciA1LjIg
  >> "!B64TMP!" echo YWJvdmUsIGFsbAplbmQgdXNlciBsaWNlbnNlIGFncmVlbWVudHMgKGV4Y2x1ZGluZyBkaXN0cmli
  >> "!B64TMP!" echo dXRvcnMgYW5kIHJlc2VsbGVycykgd2hpY2gKaGF2ZSBiZWVuIHZhbGlkbHkgZ3JhbnRlZCBieSBZ
  >> "!B64TMP!" echo b3Ugb3IgWW91ciBkaXN0cmlidXRvcnMgdW5kZXIgdGhpcyBMaWNlbnNlCnByaW9yIHRvIHRlcm1p
  >> "!B64TMP!" echo bmF0aW9uIHNoYWxsIHN1cnZpdmUgdGVybWluYXRpb24uCgoqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioKKiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAqCiogIDYuIERpc2NsYWltZXIgb2YgV2FycmFudHkgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgKgoqICAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAq
  >> "!B64TMP!" echo CiogIENvdmVyZWQgU29mdHdhcmUgaXMgcHJvdmlkZWQgdW5kZXIgdGhpcyBMaWNlbnNlIG9uIGFu
  >> "!B64TMP!" echo ICJhcyBpcyIgICAgICAgKgoqICBiYXNpcywgd2l0aG91dCB3YXJyYW50eSBvZiBhbnkga2luZCwg
  >> "!B64TMP!" echo ZWl0aGVyIGV4cHJlc3NlZCwgaW1wbGllZCwgb3IgICoKKiAgc3RhdHV0b3J5LCBpbmNsdWRpbmcs
  >> "!B64TMP!" echo IHdpdGhvdXQgbGltaXRhdGlvbiwgd2FycmFudGllcyB0aGF0IHRoZSAgICAgICAqCiogIENvdmVy
  >> "!B64TMP!" echo ZWQgU29mdHdhcmUgaXMgZnJlZSBvZiBkZWZlY3RzLCBtZXJjaGFudGFibGUsIGZpdCBmb3IgYSAg
  >> "!B64TMP!" echo ICAgICAgKgoqICBwYXJ0aWN1bGFyIHB1cnBvc2Ugb3Igbm9uLWluZnJpbmdpbmcuIFRoZSBlbnRp
  >> "!B64TMP!" echo cmUgcmlzayBhcyB0byB0aGUgICAgICoKKiAgcXVhbGl0eSBhbmQgcGVyZm9ybWFuY2Ugb2YgdGhl
  >> "!B64TMP!" echo IENvdmVyZWQgU29mdHdhcmUgaXMgd2l0aCBZb3UuICAgICAgICAqCiogIFNob3VsZCBhbnkgQ292
  >> "!B64TMP!" echo ZXJlZCBTb2Z0d2FyZSBwcm92ZSBkZWZlY3RpdmUgaW4gYW55IHJlc3BlY3QsIFlvdSAgICAgKgoq
  >> "!B64TMP!" echo ICAobm90IGFueSBDb250cmlidXRvcikgYXNzdW1lIHRoZSBjb3N0IG9mIGFueSBuZWNlc3Nhcnkg
  >> "!B64TMP!" echo c2VydmljaW5nLCAgICoKKiAgcmVwYWlyLCBvciBjb3JyZWN0aW9uLiBUaGlzIGRpc2NsYWltZXIg
  >> "!B64TMP!" echo b2Ygd2FycmFudHkgY29uc3RpdHV0ZXMgYW4gICAqCiogIGVzc2VudGlhbCBwYXJ0IG9mIHRoaXMg
  >> "!B64TMP!" echo TGljZW5zZS4gTm8gdXNlIG9mIGFueSBDb3ZlcmVkIFNvZnR3YXJlIGlzICAgKgoqICBhdXRob3Jp
  >> "!B64TMP!" echo emVkIHVuZGVyIHRoaXMgTGljZW5zZSBleGNlcHQgdW5kZXIgdGhpcyBkaXNjbGFpbWVyLiAgICAg
  >> "!B64TMP!" echo ICAgICoKKiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAqCioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKgoKKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqCiog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgKgoqICA3LiBMaW1pdGF0aW9uIG9mIExpYWJpbGl0eSAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKiAgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAqCiogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgKgoqICBVbmRlciBubyBjaXJjdW1zdGFuY2VzIGFuZCB1bmRlciBubyBsZWdhbCB0aGVvcnks
  >> "!B64TMP!" echo IHdoZXRoZXIgdG9ydCAgICAgICoKKiAgKGluY2x1ZGluZyBuZWdsaWdlbmNlKSwgY29udHJhY3Qs
  >> "!B64TMP!" echo IG9yIG90aGVyd2lzZSwgc2hhbGwgYW55ICAgICAgICAgICAqCiogIENvbnRyaWJ1dG9yLCBvciBh
  >> "!B64TMP!" echo bnlvbmUgd2hvIGRpc3RyaWJ1dGVzIENvdmVyZWQgU29mdHdhcmUgYXMgICAgICAgICAgKgoqICBw
  >> "!B64TMP!" echo ZXJtaXR0ZWQgYWJvdmUsIGJlIGxpYWJsZSB0byBZb3UgZm9yIGFueSBkaXJlY3QsIGluZGlyZWN0
  >> "!B64TMP!" echo LCAgICAgICAgICoKKiAgc3BlY2lhbCwgaW5jaWRlbnRhbCwgb3IgY29uc2VxdWVudGlhbCBkYW1h
  >> "!B64TMP!" echo Z2VzIG9mIGFueSBjaGFyYWN0ZXIgICAgICAqCiogIGluY2x1ZGluZywgd2l0aG91dCBsaW1pdGF0
  >> "!B64TMP!" echo aW9uLCBkYW1hZ2VzIGZvciBsb3N0IHByb2ZpdHMsIGxvc3Mgb2YgICAgKgoqICBnb29kd2lsbCwg
  >> "!B64TMP!" echo d29yayBzdG9wcGFnZSwgY29tcHV0ZXIgZmFpbHVyZSBvciBtYWxmdW5jdGlvbiwgb3IgYW55ICAg
  >> "!B64TMP!" echo ICoKKiAgYW5kIGFsbCBvdGhlciBjb21tZXJjaWFsIGRhbWFnZXMgb3IgbG9zc2VzLCBldmVuIGlm
  >> "!B64TMP!" echo IHN1Y2ggcGFydHkgICAgICAqCiogIHNoYWxsIGhhdmUgYmVlbiBpbmZvcm1lZCBvZiB0aGUgcG9z
  >> "!B64TMP!" echo c2liaWxpdHkgb2Ygc3VjaCBkYW1hZ2VzLiBUaGlzICAgKgoqICBsaW1pdGF0aW9uIG9mIGxpYWJp
  >> "!B64TMP!" echo bGl0eSBzaGFsbCBub3QgYXBwbHkgdG8gbGlhYmlsaXR5IGZvciBkZWF0aCBvciAgICoKKiAgcGVy
  >> "!B64TMP!" echo c29uYWwgaW5qdXJ5IHJlc3VsdGluZyBmcm9tIHN1Y2ggcGFydHkncyBuZWdsaWdlbmNlIHRvIHRo
  >> "!B64TMP!" echo ZSAgICAgICAqCiogIGV4dGVudCBhcHBsaWNhYmxlIGxhdyBwcm9oaWJpdHMgc3VjaCBsaW1pdGF0
  >> "!B64TMP!" echo aW9uLiBTb21lICAgICAgICAgICAgICAgKgoqICBqdXJpc2RpY3Rpb25zIGRvIG5vdCBhbGxvdyB0
  >> "!B64TMP!" echo aGUgZXhjbHVzaW9uIG9yIGxpbWl0YXRpb24gb2YgICAgICAgICAgICoKKiAgaW5jaWRlbnRhbCBv
  >> "!B64TMP!" echo ciBjb25zZXF1ZW50aWFsIGRhbWFnZXMsIHNvIHRoaXMgZXhjbHVzaW9uIGFuZCAgICAgICAgICAq
  >> "!B64TMP!" echo CiogIGxpbWl0YXRpb24gbWF5IG5vdCBhcHBseSB0byBZb3UuICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgKgoqICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICoKKioqKioqKioqKioqKioqKioqKioqKioq
  >> "!B64TMP!" echo KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqCgo4LiBMaXRp
  >> "!B64TMP!" echo Z2F0aW9uCi0tLS0tLS0tLS0tLS0KCkFueSBsaXRpZ2F0aW9uIHJlbGF0aW5nIHRvIHRoaXMgTGlj
  >> "!B64TMP!" echo ZW5zZSBtYXkgYmUgYnJvdWdodCBvbmx5IGluIHRoZQpjb3VydHMgb2YgYSBqdXJpc2RpY3Rpb24g
  >> "!B64TMP!" echo d2hlcmUgdGhlIGRlZmVuZGFudCBtYWludGFpbnMgaXRzIHByaW5jaXBhbApwbGFjZSBvZiBidXNp
  >> "!B64TMP!" echo bmVzcyBhbmQgc3VjaCBsaXRpZ2F0aW9uIHNoYWxsIGJlIGdvdmVybmVkIGJ5IGxhd3Mgb2YgdGhh
  >> "!B64TMP!" echo dApqdXJpc2RpY3Rpb24sIHdpdGhvdXQgcmVmZXJlbmNlIHRvIGl0cyBjb25mbGljdC1vZi1sYXcg
  >> "!B64TMP!" echo cHJvdmlzaW9ucy4KTm90aGluZyBpbiB0aGlzIFNlY3Rpb24gc2hhbGwgcHJldmVudCBhIHBhcnR5
  >> "!B64TMP!" echo J3MgYWJpbGl0eSB0byBicmluZwpjcm9zcy1jbGFpbXMgb3IgY291bnRlci1jbGFpbXMuCgo5LiBN
  >> "!B64TMP!" echo aXNjZWxsYW5lb3VzCi0tLS0tLS0tLS0tLS0tLS0KClRoaXMgTGljZW5zZSByZXByZXNlbnRzIHRo
  >> "!B64TMP!" echo ZSBjb21wbGV0ZSBhZ3JlZW1lbnQgY29uY2VybmluZyB0aGUgc3ViamVjdAptYXR0ZXIgaGVyZW9m
  >> "!B64TMP!" echo LiBJZiBhbnkgcHJvdmlzaW9uIG9mIHRoaXMgTGljZW5zZSBpcyBoZWxkIHRvIGJlCnVuZW5mb3Jj
  >> "!B64TMP!" echo ZWFibGUsIHN1Y2ggcHJvdmlzaW9uIHNoYWxsIGJlIHJlZm9ybWVkIG9ubHkgdG8gdGhlIGV4dGVu
  >> "!B64TMP!" echo dApuZWNlc3NhcnkgdG8gbWFrZSBpdCBlbmZvcmNlYWJsZS4gQW55IGxhdyBvciByZWd1bGF0aW9u
  >> "!B64TMP!" echo IHdoaWNoIHByb3ZpZGVzCnRoYXQgdGhlIGxhbmd1YWdlIG9mIGEgY29udHJhY3Qgc2hhbGwgYmUg
  >> "!B64TMP!" echo Y29uc3RydWVkIGFnYWluc3QgdGhlIGRyYWZ0ZXIKc2hhbGwgbm90IGJlIHVzZWQgdG8gY29uc3Ry
  >> "!B64TMP!" echo dWUgdGhpcyBMaWNlbnNlIGFnYWluc3QgYSBDb250cmlidXRvci4KCjEwLiBWZXJzaW9ucyBvZiB0
  >> "!B64TMP!" echo aGUgTGljZW5zZQotLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCjEwLjEuIE5ldyBWZXJzaW9u
  >> "!B64TMP!" echo cwoKTW96aWxsYSBGb3VuZGF0aW9uIGlzIHRoZSBsaWNlbnNlIHN0ZXdhcmQuIEV4Y2VwdCBhcyBw
  >> "!B64TMP!" echo cm92aWRlZCBpbiBTZWN0aW9uCjEwLjMsIG5vIG9uZSBvdGhlciB0aGFuIHRoZSBsaWNlbnNlIHN0
  >> "!B64TMP!" echo ZXdhcmQgaGFzIHRoZSByaWdodCB0byBtb2RpZnkgb3IKcHVibGlzaCBuZXcgdmVyc2lvbnMgb2Yg
  >> "!B64TMP!" echo dGhpcyBMaWNlbnNlLiBFYWNoIHZlcnNpb24gd2lsbCBiZSBnaXZlbiBhCmRpc3Rpbmd1aXNoaW5n
  >> "!B64TMP!" echo IHZlcnNpb24gbnVtYmVyLgoKMTAuMi4gRWZmZWN0IG9mIE5ldyBWZXJzaW9ucwoKWW91IG1heSBk
  >> "!B64TMP!" echo aXN0cmlidXRlIHRoZSBDb3ZlcmVkIFNvZnR3YXJlIHVuZGVyIHRoZSB0ZXJtcyBvZiB0aGUgdmVy
  >> "!B64TMP!" echo c2lvbgpvZiB0aGUgTGljZW5zZSB1bmRlciB3aGljaCBZb3Ugb3JpZ2luYWxseSByZWNlaXZlZCB0
  >> "!B64TMP!" echo aGUgQ292ZXJlZCBTb2Z0d2FyZSwKb3IgdW5kZXIgdGhlIHRlcm1zIG9mIGFueSBzdWJzZXF1ZW50
  >> "!B64TMP!" echo IHZlcnNpb24gcHVibGlzaGVkIGJ5IHRoZSBsaWNlbnNlCnN0ZXdhcmQuCgoxMC4zLiBNb2RpZmll
  >> "!B64TMP!" echo ZCBWZXJzaW9ucwoKSWYgeW91IGNyZWF0ZSBzb2Z0d2FyZSBub3QgZ292ZXJuZWQgYnkgdGhpcyBM
  >> "!B64TMP!" echo aWNlbnNlLCBhbmQgeW91IHdhbnQgdG8KY3JlYXRlIGEgbmV3IGxpY2Vuc2UgZm9yIHN1Y2ggc29m
  >> "!B64TMP!" echo dHdhcmUsIHlvdSBtYXkgY3JlYXRlIGFuZCB1c2UgYQptb2RpZmllZCB2ZXJzaW9uIG9mIHRoaXMg
  >> "!B64TMP!" echo TGljZW5zZSBpZiB5b3UgcmVuYW1lIHRoZSBsaWNlbnNlIGFuZCByZW1vdmUKYW55IHJlZmVyZW5j
  >> "!B64TMP!" echo ZXMgdG8gdGhlIG5hbWUgb2YgdGhlIGxpY2Vuc2Ugc3Rld2FyZCAoZXhjZXB0IHRvIG5vdGUgdGhh
  >> "!B64TMP!" echo dApzdWNoIG1vZGlmaWVkIGxpY2Vuc2UgZGlmZmVycyBmcm9tIHRoaXMgTGljZW5zZSkuCgoxMC40
  >> "!B64TMP!" echo LiBEaXN0cmlidXRpbmcgU291cmNlIENvZGUgRm9ybSB0aGF0IGlzIEluY29tcGF0aWJsZSBXaXRo
  >> "!B64TMP!" echo IFNlY29uZGFyeQpMaWNlbnNlcwoKSWYgWW91IGNob29zZSB0byBkaXN0cmlidXRlIFNvdXJjZSBD
  >> "!B64TMP!" echo b2RlIEZvcm0gdGhhdCBpcyBJbmNvbXBhdGlibGUgV2l0aApTZWNvbmRhcnkgTGljZW5zZXMgdW5k
  >> "!B64TMP!" echo ZXIgdGhlIHRlcm1zIG9mIHRoaXMgdmVyc2lvbiBvZiB0aGUgTGljZW5zZSwgdGhlCm5vdGljZSBk
  >> "!B64TMP!" echo ZXNjcmliZWQgaW4gRXhoaWJpdCBCIG9mIHRoaXMgTGljZW5zZSBtdXN0IGJlIGF0dGFjaGVkLgoK
  >> "!B64TMP!" echo RXhoaWJpdCBBIC0gU291cmNlIENvZGUgRm9ybSBMaWNlbnNlIE5vdGljZQotLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCgogIFRoaXMgU291cmNlIENvZGUgRm9ybSBp
  >> "!B64TMP!" echo cyBzdWJqZWN0IHRvIHRoZSB0ZXJtcyBvZiB0aGUgTW96aWxsYSBQdWJsaWMKICBMaWNlbnNlLCB2
  >> "!B64TMP!" echo LiAyLjAuIElmIGEgY29weSBvZiB0aGUgTVBMIHdhcyBub3QgZGlzdHJpYnV0ZWQgd2l0aCB0aGlz
  >> "!B64TMP!" echo CiAgZmlsZSwgWW91IGNhbiBvYnRhaW4gb25lIGF0IGh0dHBzOi8vbW96aWxsYS5vcmcvTVBMLzIu
  >> "!B64TMP!" echo MC8uCgpJZiBpdCBpcyBub3QgcG9zc2libGUgb3IgZGVzaXJhYmxlIHRvIHB1dCB0aGUgbm90aWNl
  >> "!B64TMP!" echo IGluIGEgcGFydGljdWxhcgpmaWxlLCB0aGVuIFlvdSBtYXkgaW5jbHVkZSB0aGUgbm90aWNlIGlu
  >> "!B64TMP!" echo IGEgbG9jYXRpb24gKHN1Y2ggYXMgYSBMSUNFTlNFCmZpbGUgaW4gYSByZWxldmFudCBkaXJlY3Rv
  >> "!B64TMP!" echo cnkpIHdoZXJlIGEgcmVjaXBpZW50IHdvdWxkIGJlIGxpa2VseSB0byBsb29rCmZvciBzdWNoIGEg
  >> "!B64TMP!" echo bm90aWNlLgoKWW91IG1heSBhZGQgYWRkaXRpb25hbCBhY2N1cmF0ZSBub3RpY2VzIG9mIGNvcHly
  >> "!B64TMP!" echo aWdodCBvd25lcnNoaXAuCgpFeGhpYml0IEIgLSAiSW5jb21wYXRpYmxlIFdpdGggU2Vjb25kYXJ5
  >> "!B64TMP!" echo IExpY2Vuc2VzIiBOb3RpY2UKLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tCgogIFRoaXMgU291cmNlIENvZGUgRm9ybSBpcyAiSW5jb21wYXRp
  >> "!B64TMP!" echo YmxlIFdpdGggU2Vjb25kYXJ5IExpY2Vuc2VzIiwgYXMKICBkZWZpbmVkIGJ5IHRoZSBNb3ppbGxh
  >> "!B64TMP!" echo IFB1YmxpYyBMaWNlbnNlLCB2LiAyLjAuCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\LICENSE"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- .gitignore ---
set "NEED_B64=1"
if exist "!SRC!\.gitignore" (
  copy /Y "!SRC!\.gitignore" "!TARGET!\.gitignore" >nul 2>&1
  if exist "!TARGET!\.gitignore" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] .gitignore  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3788869521.b64"
  > "!B64TMP!" echo IyAtLS0tIEdlbmVyYXRlZCBhdCBpbnN0YWxsIHRpbWUgKGNvbnRhaW5zIHlvdXIgcG9ydHMgYW5k
  >> "!B64TMP!" echo IHNlY3JldHMpIC0tLS0KLmVudgouZW52LmJhay4qCgojIC0tLS0gV3JpdHRlbiBieSB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbGVyIGludG8gaW5zdGFsbGVkIHNraWxsIGNvcGllcyAtLS0tCiMgKHRoZSBzb3VyY2UgY29w
  >> "!B64TMP!" echo eSBpbiB0aGUgcmVwbyBtdXN0IHN0YXkgY2xlYW47IHRoZSBpbnN0YWxsZXIgcmVjb3JkcyB0aGUK
  >> "!B64TMP!" echo IyAgaW5zdGFsbCBwYXRoIGhlcmUgd2hlbiBpdCBjb3BpZXMgdGhlIHNraWxsIHRvIH4vLmFnZW50
  >> "!B64TMP!" echo cy9za2lsbHMvbG9jYWwtd2ViKQpsb2NhbC13ZWIvaW5zdGFsbC1kaXIudHh0CgojIC0tLS0gUHl0
  >> "!B64TMP!" echo aG9uIGJ5dGVjb2RlIChza2lsbCBzY3JpcHRzKSAtLS0tCl9fcHljYWNoZV9fLwoqLnB5YwoKIyAt
  >> "!B64TMP!" echo LS0tIE9TIGp1bmsgLS0tLQouRFNfU3RvcmUKVGh1bWJzLmRiCmRlc2t0b3AuaW5pCgojIC0tLS0g
  >> "!B64TMP!" echo TG9ncyAtLS0tCioubG9nCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\.gitignore"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- .gitattributes ---
set "NEED_B64=1"
if exist "!SRC!\.gitattributes" (
  copy /Y "!SRC!\.gitattributes" "!TARGET!\.gitattributes" >nul 2>&1
  if exist "!TARGET!\.gitattributes" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] .gitattributes  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2379549047.b64"
  > "!B64TMP!" echo IyBOb3JtYWxpemUgdGV4dCBmaWxlcyBpbiB0aGUgcmVwbzsga2VlcCBwbGF0Zm9ybS1uYXRpdmUg
  >> "!B64TMP!" echo bGluZSBlbmRpbmdzIG9uIGNoZWNrb3V0CiogdGV4dD1hdXRvCgojIFdpbmRvd3MgYmF0Y2ggZmls
  >> "!B64TMP!" echo ZXMgbXVzdCBrZWVwIENSTEYgd29ya2luZyBjb3BpZXMKKi5iYXQgdGV4dCBlb2w9Y3JsZgoqLmNt
  >> "!B64TMP!" echo ZCB0ZXh0IGVvbD1jcmxmCioucHMxIHRleHQgZW9sPWNybGYKCiMgVW5peCBzY3JpcHRzIG11c3Qg
  >> "!B64TMP!" echo c3RheSBMRgoqLnNoIHRleHQgZW9sPWxmCioucHkgdGV4dCBlb2w9bGYKKi55bWwgdGV4dCBlb2w9
  >> "!B64TMP!" echo bGYKKi55YW1sIHRleHQgZW9sPWxmCgojIERvY3MKKi5tZCB0ZXh0CkxJQ0VOU0UgdGV4dAo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\.gitattributes"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Run.bat ---
set "NEED_B64=1"
if exist "!SRC!\Run.bat" (
  copy /Y "!SRC!\Run.bat" "!TARGET!\Run.bat" >nul 2>&1
  if exist "!TARGET!\Run.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Run.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1962629694.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFJ1bg0KDQpjZCAvZCAiJX5kcDAiDQoNCndoZXJlIGRv
  >> "!B64TMP!" echo Y2tlciA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBEb2NrZXIg
  >> "!B64TMP!" echo aXMgbm90IGluc3RhbGxlZCBvciBub3Qgb24gUEFUSC4gSW5zdGFsbCBEb2NrZXIgRGVza3RvcCBm
  >> "!B64TMP!" echo aXJzdC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQpkb2NrZXIgaW5mbyA+bnVsIDI+JjENCmlm
  >> "!B64TMP!" echo IGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5u
  >> "!B64TMP!" echo aW5nLiBTdGFydCBEb2NrZXIgRGVza3RvcCBmaXJzdC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQop
  >> "!B64TMP!" echo DQoNCmlmIG5vdCBleGlzdCAiLmVudiIgKA0KICBlY2hvIFtFUlJPUl0gTm8gLmVudiBmaWxlIGZv
  >> "!B64TMP!" echo dW5kIGluIHRoaXMgZm9sZGVyLg0KICBlY2hvICAgUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJh
  >> "!B64TMP!" echo dCBmaXJzdCB0byBjcmVhdGUgdGhlIGNvbmZpZ3VyYXRpb24uDQogIHBhdXNlDQogIGV4aXQgL2Ig
  >> "!B64TMP!" echo MQ0KKQ0KDQplY2hvIFN0YXJ0aW5nIExvY2FsIFNlYXJjaCAoRmlyZWNyYXdsICsgU2VhclhORyku
  >> "!B64TMP!" echo Li4NCmRvY2tlciBjb21wb3NlIHVwIC1kDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvLg0KICBl
  >> "!B64TMP!" echo Y2hvIFtFUlJPUl0gRmFpbGVkIHRvIHN0YXJ0LiBTZWUgbWVzc2FnZXMgYWJvdmUuDQogIHBhdXNl
  >> "!B64TMP!" echo DQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvLg0KZWNobyBMb2NhbCBTZWFyY2ggaXMgcnVubmluZzoN
  >> "!B64TMP!" echo CmVjaG8gICBTZWFyWE5HOiAgIGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MCAgICAgIF4oY2hhbmdlIGlu
  >> "!B64TMP!" echo IC5lbnZeKQ0KZWNobyAgIEZpcmVjcmF3bDogaHR0cDovL2xvY2FsaG9zdDo5OTkxICAgICAgXihj
  >> "!B64TMP!" echo aGFuZ2UgaW4gLmVudl4pDQplY2hvLg0KZWNobyBPcGVuIHRoZSBTZWFyWE5HIFVJIGluIHlvdXIg
  >> "!B64TMP!" echo YnJvd3Nlciwgb3IgcXVlcnkgdGhlIEpTT04gQVBJIGZyb20geW91ciBtb2RlbHMuDQplY2hvIFVz
  >> "!B64TMP!" echo ZSBTdG9wLmJhdCB0byBzdG9wIHRoZSBzdGFjay4NCmVjaG8uDQpwYXVzZQ0KZXhpdCAvYiAwDQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Run.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Stop.bat ---
set "NEED_B64=1"
if exist "!SRC!\Stop.bat" (
  copy /Y "!SRC!\Stop.bat" "!TARGET!\Stop.bat" >nul 2>&1
  if exist "!TARGET!\Stop.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Stop.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2263657140.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFN0b3ANCg0KY2QgL2QgIiV+ZHAwIg0KDQp3aGVyZSBk
  >> "!B64TMP!" echo b2NrZXIgPm51bCAyPiYxDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvIFtFUlJPUl0gRG9ja2Vy
  >> "!B64TMP!" echo IGlzIG5vdCBpbnN0YWxsZWQgb3Igbm90IG9uIFBBVEguDQogIHBhdXNlDQogIGV4aXQgL2IgMQ0K
  >> "!B64TMP!" echo KQ0KDQppZiBub3QgZXhpc3QgIi5lbnYiICgNCiAgZWNobyBbRVJST1JdIE5vIC5lbnYgZmlsZSBm
  >> "!B64TMP!" echo b3VuZCBpbiB0aGlzIGZvbGRlci4gTm90aGluZyB0byBzdG9wLg0KICBwYXVzZQ0KICBleGl0IC9i
  >> "!B64TMP!" echo IDENCikNCg0KZWNobyBTdG9wcGluZyBMb2NhbCBTZWFyY2ggY29udGFpbmVycyAoZGF0YSBpcyBw
  >> "!B64TMP!" echo cmVzZXJ2ZWQpLi4uDQpkb2NrZXIgY29tcG9zZSBkb3duDQppZiBlcnJvcmxldmVsIDEgKA0KICBl
  >> "!B64TMP!" echo Y2hvLg0KICBlY2hvIFtFUlJPUl0gRmFpbGVkIHRvIHN0b3AuIFNlZSBtZXNzYWdlcyBhYm92ZS4N
  >> "!B64TMP!" echo CiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQoNCmVjaG8uDQplY2hvIExvY2FsIFNlYXJjaCBzdG9w
  >> "!B64TMP!" echo cGVkLiBEYXRhIGlzIHByZXNlcnZlZCBpbiBEb2NrZXIgdm9sdW1lcy4NCmVjaG8gUnVuIFJ1bi5i
  >> "!B64TMP!" echo YXQgdG8gc3RhcnQgaXQgYWdhaW4uDQplY2hvLg0KcGF1c2UNCmV4aXQgL2IgMA0K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Stop.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Update.bat ---
set "NEED_B64=1"
if exist "!SRC!\Update.bat" (
  copy /Y "!SRC!\Update.bat" "!TARGET!\Update.bat" >nul 2>&1
  if exist "!TARGET!\Update.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Update.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3559231701.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQpjaGNwIDY1MDAxID5u
  >> "!B64TMP!" echo dWwNCnRpdGxlIExvY2FsIFNlYXJjaCAtIFVwZGF0ZQ0KDQpjZCAvZCAiJX5kcDAiDQoNCndoZXJl
  >> "!B64TMP!" echo IGRvY2tlciA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VSUk9SXSBEb2Nr
  >> "!B64TMP!" echo ZXIgaXMgbm90IGluc3RhbGxlZCBvciBub3Qgb24gUEFUSC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAx
  >> "!B64TMP!" echo DQopDQpkb2NrZXIgaW5mbyA+bnVsIDI+JjENCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8gW0VS
  >> "!B64TMP!" echo Uk9SXSBEb2NrZXIgZW5naW5lIGlzIG5vdCBydW5uaW5nLiBTdGFydCBEb2NrZXIgRGVza3RvcCBm
  >> "!B64TMP!" echo aXJzdC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQoNCmlmIG5vdCBleGlzdCAiLmVudiIgKA0K
  >> "!B64TMP!" echo ICBlY2hvIFtFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kIGluIHRoaXMgZm9sZGVyLg0KICBlY2hv
  >> "!B64TMP!" echo ICAgUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCBmaXJzdCB0byBjcmVhdGUgdGhlIGNvbmZp
  >> "!B64TMP!" echo Z3VyYXRpb24uDQogIHBhdXNlDQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvIFVwZGF0aW5nIExvY2Fs
  >> "!B64TMP!" echo IFNlYXJjaC4uLg0KZWNoby4NCmVjaG8gWzEvM10gUHVsbGluZyBsYXRlc3QgaW1hZ2VzLi4uDQpk
  >> "!B64TMP!" echo b2NrZXIgY29tcG9zZSBwdWxsDQppZiBlcnJvcmxldmVsIDEgKA0KICBlY2hvLg0KICBlY2hvIFtX
  >> "!B64TMP!" echo QVJOSU5HXSBTb21lIGltYWdlcyBmYWlsZWQgdG8gcHVsbC4gQ29udGludWluZyB3aXRoIHdoYXQg
  >> "!B64TMP!" echo aXMgYXZhaWxhYmxlLg0KKQ0KDQplY2hvLg0KZWNobyBbMi8zXSBSZWNyZWF0aW5nIGNvbnRhaW5l
  >> "!B64TMP!" echo cnMgd2l0aCB1cGRhdGVkIGltYWdlcyAoZGF0YSBpcyBwcmVzZXJ2ZWQpLi4uDQpkb2NrZXIgY29t
  >> "!B64TMP!" echo cG9zZSB1cCAtZA0KaWYgZXJyb3JsZXZlbCAxICgNCiAgZWNoby4NCiAgZWNobyBbRVJST1JdIEZh
  >> "!B64TMP!" echo aWxlZCB0byByZWNyZWF0ZSBjb250YWluZXJzLiBTZWUgbWVzc2FnZXMgYWJvdmUuDQogIHBhdXNl
  >> "!B64TMP!" echo DQogIGV4aXQgL2IgMQ0KKQ0KDQplY2hvLg0KZWNobyBbMy8zXSBSZWZyZXNoaW5nIHRoZSBsb2Nh
  >> "!B64TMP!" echo bC13ZWItc2VhcmNoIGFnZW50IHNraWxsLi4uDQppZiBleGlzdCAiJX5kcDBsb2NhbC13ZWItc2Vh
  >> "!B64TMP!" echo cmNoXFNLSUxMLm1kIiAoDQogIHNldCAiU0tJTExfRElSPSVVU0VSUFJPRklMRSVcLmFnZW50c1xz
  >> "!B64TMP!" echo a2lsbHNcbG9jYWwtd2ViLXNlYXJjaCINCiAgaWYgZXhpc3QgIiFTS0lMTF9ESVIhIiByZCAvcyAv
  >> "!B64TMP!" echo cSAiIVNLSUxMX0RJUiEiDQogIGlmIG5vdCBleGlzdCAiJVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNr
  >> "!B64TMP!" echo aWxscyIgbWtkaXIgIiVVU0VSUFJPRklMRSVcLmFnZW50c1xza2lsbHMiDQogIHhjb3B5IC9FIC9J
  >> "!B64TMP!" echo IC9ZIC9RICIlfmRwMGxvY2FsLXdlYi1zZWFyY2giICIhU0tJTExfRElSISIgPm51bA0KICBpZiBl
  >> "!B64TMP!" echo cnJvcmxldmVsIDEgKA0KICAgIGVjaG8gICBbV0FSTklOR10gQ291bGQgbm90IGNvcHkgdGhlIHNr
  >> "!B64TMP!" echo aWxsIHRvICFTS0lMTF9ESVIhLg0KICApIGVsc2UgKA0KICAgID4gIiFTS0lMTF9ESVIhXGluc3Rh
  >> "!B64TMP!" echo bGwtZGlyLnR4dCIgZWNobyAlfmRwMA0KICAgIGVjaG8gICBTa2lsbCByZWZyZXNoZWQgYXQgIVNL
  >> "!B64TMP!" echo SUxMX0RJUiENCiAgKQ0KKSBlbHNlICgNCiAgZWNobyAgIGxvY2FsLXdlYi1zZWFyY2ggc2tpbGwg
  >> "!B64TMP!" echo c291cmNlIG5vdCBmb3VuZCBpbiB0aGlzIGZvbGRlciAtIHNraXBwaW5nLg0KKQ0KDQplY2hvLg0K
  >> "!B64TMP!" echo ZWNobyBVcGRhdGUgY29tcGxldGUuIERhdGEgdm9sdW1lcyB3ZXJlIHByZXNlcnZlZC4NCmVjaG8g
  >> "!B64TMP!" echo ICAtIElmIHlvdSBjaGFuZ2VkIHBvcnRzIG9yIExMTSBzZXR0aW5ncyBpbiAuZW52LCB0aGV5IGFy
  >> "!B64TMP!" echo ZSBub3cgYXBwbGllZC4NCmVjaG8gICAtIFRoZSBsb2NhbC13ZWItc2VhcmNoIHNraWxsIHdhcyBy
  >> "!B64TMP!" echo ZS1zeW5jZWQgZnJvbSB0aGlzIGZvbGRlci4NCmVjaG8gICAtIFRvIHVwZGF0ZSB0aGUgU2VhclhO
  >> "!B64TMP!" echo RyBzZXR0aW5ncy55bWwgb3IgZG9ja2VyLWNvbXBvc2UueW1sIHRlbXBsYXRlLA0KZWNobyAgICAg
  >> "!B64TMP!" echo cmUtcnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLmJhdCAoaXQgYmFja3MgdXAgeW91ciBjdXJyZW50
  >> "!B64TMP!" echo IC5lbnYpLg0KZWNoby4NCnBhdXNlDQpleGl0IC9iIDANCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Update.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- Uninstall.bat ---
set "NEED_B64=1"
if exist "!SRC!\Uninstall.bat" (
  copy /Y "!SRC!\Uninstall.bat" "!TARGET!\Uninstall.bat" >nul 2>&1
  if exist "!TARGET!\Uninstall.bat" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] Uninstall.bat  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS4046764878.b64"
  > "!B64TMP!" echo QGVjaG8gb2ZmDQpzZXRsb2NhbCBlbmFibGVEZWxheWVkRXhwYW5zaW9uDQp0aXRsZSBMb2NhbCBT
  >> "!B64TMP!" echo ZWFyY2ggLSBVbmluc3RhbGwNClJFTSAgUHJvbXB0cyBydW4gb24gYSBjb2RlIHBhZ2Ugb3RoZXIg
  >> "!B64TMP!" echo dGhhbiA2NTAwMTogd2hpbGUgdGhlIGNvbnNvbGUgaXMgb24gNjUwMDENClJFTSAgKFVURi04KSwg
  >> "!B64TMP!" echo c2V0IC9wIHJldHVybnMgYW4gZW1wdHkgbGluZSBmb3IgcmVkaXJlY3RlZCBvciBwaXBlZCBzdGRp
  >> "!B64TMP!" echo biwgc28NClJFTSAgc2NyaXB0ZWQgYW5zd2VycyBhcmUgbG9zdC4gVGhlIGNvZGUgcGFnZSB0aGUg
  >> "!B64TMP!" echo Y29uc29sZSBzdGFydGVkIG9uIGlzIHVzZWQsIG9yDQpSRU0gIDQzNyB3aGVuIGl0IGlzIGFscmVh
  >> "!B64TMP!" echo ZHkgNjUwMDEgKGNoY3AgcGVyc2lzdHMgYWZ0ZXIgYSBzY3JpcHQgZW5kcykuIFVURi04IGlzDQpS
  >> "!B64TMP!" echo RU0gIGVuYWJsZWQgYWZ0ZXIgdGhlIGxhc3QgcHJvbXB0Lg0Kc2V0ICJMU19QUk9NUFRfQ1A9NDM3
  >> "!B64TMP!" echo Ig0KZm9yIC9mICJ0b2tlbnM9MiBkZWxpbXM9OiIgJSVjIGluICgnY2hjcCcpIGRvIGZvciAvZiAl
  >> "!B64TMP!" echo JW4gaW4gKCIlJWMiKSBkbyBzZXQgIkxTX1BST01QVF9DUD0lJW4iDQppZiAiIUxTX1BST01QVF9D
  >> "!B64TMP!" echo UCEiPT0iNjUwMDEiIHNldCAiTFNfUFJPTVBUX0NQPTQzNyINCmNoY3AgIUxTX1BST01QVF9DUCEg
  >> "!B64TMP!" echo Pm51bCAyPiYxDQoNCmNkIC9kICIlfmRwMCINCg0Kd2hlcmUgZG9ja2VyID5udWwgMj4mMQ0KaWYg
  >> "!B64TMP!" echo ZXJyb3JsZXZlbCAxICgNCiAgZWNobyBbRVJST1JdIERvY2tlciBpcyBub3QgaW5zdGFsbGVkIG9y
  >> "!B64TMP!" echo IG5vdCBvbiBQQVRILg0KICBlY2hvICAgWW91IGNhbiBtYW51YWxseSBkZWxldGUgdGhpcyBmb2xk
  >> "!B64TMP!" echo ZXIgdG8gcmVtb3ZlIHRoZSBmaWxlcy4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQopDQoNCmlmIG5v
  >> "!B64TMP!" echo dCBleGlzdCAiLmVudiIgKA0KICBlY2hvIFtFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kIGluIHRo
  >> "!B64TMP!" echo aXMgZm9sZGVyLiBOb3RoaW5nIHRvIHVuaW5zdGFsbC4NCiAgcGF1c2UNCiAgZXhpdCAvYiAxDQop
  >> "!B64TMP!" echo DQoNCmVjaG8gPT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09DQplY2hvICAgVW5pbnN0YWxsIExvY2FsIFNlYXJjaA0KZWNobyA9PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0NCmVj
  >> "!B64TMP!" echo aG8gVGhpcyB3aWxsOg0KZWNobyAgIDEuIFN0b3AgYW5kIHJlbW92ZSBhbGwgTG9jYWwgU2VhcmNo
  >> "!B64TMP!" echo IGNvbnRhaW5lcnMuDQplY2hvICAgMi4gUmVtb3ZlIHRoZSBEb2NrZXIgVk9MVU1FUyAoRmlyZWNy
  >> "!B64TMP!" echo YXdsIGpvYiBzdGF0ZSwgcmVkaXMgY2FjaGUsDQplY2hvICAgICAgcmFiYml0bXEvcG9zdGdyZXMg
  >> "!B64TMP!" echo ZGF0YSkuIFRoaXMgZGVsZXRlcyBhbGwgc3RvcmVkIGRhdGEuDQplY2hvICAgMy4gUmVtb3ZlIHRo
  >> "!B64TMP!" echo ZSBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNraWxsIGZyb20NCmVjaG8gICAgICAlVVNFUlBST0ZJ
  >> "!B64TMP!" echo TEUlXC5hZ2VudHNcc2tpbGxzXGxvY2FsLXdlYi1zZWFyY2gNCmVjaG8gICA0LiAoT3B0aW9uYWwp
  >> "!B64TMP!" echo IERlbGV0ZSB0aGUgaW5zdGFsbCBmb2xkZXIgYW5kIGFsbCBpdHMgZmlsZXMuDQplY2hvLg0KZWNo
  >> "!B64TMP!" echo byAgIFB1bGxlZCBEb2NrZXIgaW1hZ2VzIGFyZSBOT1QgcmVtb3ZlZCAodXNlICJkb2NrZXIgaW1h
  >> "!B64TMP!" echo Z2UgcHJ1bmUiIHRvDQplY2hvICAgcmVjbGFpbSB0aGF0IGRpc2sgc3BhY2Ugc2VwYXJhdGVseSku
  >> "!B64TMP!" echo DQplY2hvLg0Kc2V0ICJDT05GSVJNPSINCnNldCAvcCBDT05GSVJNPSJDb250aW51ZSB3aXRoIHVu
  >> "!B64TMP!" echo aW5zdGFsbD8gW3kvTl06ICINCmlmIC9pIG5vdCAiIUNPTkZJUk0hIj09InkiICggZWNobyBVbmlu
  >> "!B64TMP!" echo c3RhbGwgY2FuY2VsbGVkLiAmIHBhdXNlICYgZXhpdCAvYiAwICkNClJFTSAgQWxsIHByb21wdHMg
  >> "!B64TMP!" echo YXJlIGFuc3dlcmVkIC0gc2FmZSB0byBzd2l0Y2ggdG8gVVRGLTggZm9yIHRoZSBvdXRwdXQgcGhh
  >> "!B64TMP!" echo c2UuDQpjaGNwIDY1MDAxID5udWwNCg0KZWNoby4NCmVjaG8gU3RvcHBpbmcgYW5kIHJlbW92aW5n
  >> "!B64TMP!" echo IGNvbnRhaW5lcnMgKyB2b2x1bWVzLi4uDQpkb2NrZXIgY29tcG9zZSBkb3duIC12IC0tcmVtb3Zl
  >> "!B64TMP!" echo LW9ycGhhbnMNCmlmIGVycm9ybGV2ZWwgMSAoDQogIGVjaG8uDQogIGVjaG8gW1dBUk5JTkddIGRv
  >> "!B64TMP!" echo Y2tlciBjb21wb3NlIGRvd24gcmVwb3J0ZWQgZXJyb3JzLg0KICBlY2hvICAgWW91IG1heSBuZWVk
  >> "!B64TMP!" echo IHRvIHJlbW92ZSBsZWZ0b3ZlciBjb250YWluZXJzIG1hbnVhbGx5LCBlLmcuOg0KICBlY2hvICAg
  >> "!B64TMP!" echo ICBkb2NrZXIgcm0gLWYgbG9jYWwtc2VhcmNoLWZpcmVjcmF3bCBsb2NhbC1zZWFyY2gtc2Vhcnhu
  >> "!B64TMP!" echo Zw0KICBlY2hvICAgICBkb2NrZXIgcm0gLWYgbG9jYWwtc2VhcmNoLXJlZGlzIGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aC1yYWJiaXRtcQ0KICBlY2hvICAgICBkb2NrZXIgcm0gLWYgbG9jYWwtc2VhcmNoLXBvc3RncmVz
  >> "!B64TMP!" echo IGxvY2FsLXNlYXJjaC1wbGF5d3JpZ2h0IGxvY2FsLXNlYXJjaC1icm93c2VybGVzcw0KKQ0KDQpl
  >> "!B64TMP!" echo Y2hvLg0KZWNobyBDb250YWluZXJzIGFuZCB2b2x1bWVzIHJlbW92ZWQuDQplY2hvLg0KZWNobyBS
  >> "!B64TMP!" echo ZW1vdmluZyB0aGUgbG9jYWwtd2ViLXNlYXJjaCBhZ2VudCBza2lsbC4uLg0Kc2V0ICJTS0lMTF9E
  >> "!B64TMP!" echo SVI9JVVTRVJQUk9GSUxFJVwuYWdlbnRzXHNraWxsc1xsb2NhbC13ZWItc2VhcmNoIg0KaWYgZXhp
  >> "!B64TMP!" echo c3QgIiFTS0lMTF9ESVIhIiAoDQogIHJkIC9zIC9xICIhU0tJTExfRElSISINCiAgZWNobyAgIFJl
  >> "!B64TMP!" echo bW92ZWQgIVNLSUxMX0RJUiENCikgZWxzZSAoDQogIGVjaG8gICBTa2lsbCBub3QgZm91bmQgXihh
  >> "!B64TMP!" echo bHJlYWR5IHJlbW92ZWReKSAtIG5vdGhpbmcgdG8gZG8uDQopDQplY2hvLg0KUkVNICBUaGUgc2Vj
  >> "!B64TMP!" echo b25kIHByb21wdCBhbHNvIG5lZWRzIGEgY29kZSBwYWdlIG90aGVyIHRoYW4gNjUwMDEgKHNlZSB0
  >> "!B64TMP!" echo b3Agb2YgZmlsZSkuDQpjaGNwICFMU19QUk9NUFRfQ1AhID5udWwgMj4mMQ0Kc2V0ICJERUxGSUxF
  >> "!B64TMP!" echo Uz0iDQpzZXQgL3AgREVMRklMRVM9IkFsc28gZGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBhbmQg
  >> "!B64TMP!" echo QUxMIGl0cyBmaWxlcz8gW3kvTl06ICINCmlmIC9pIG5vdCAiIURFTEZJTEVTISI9PSJ5IiAoDQog
  >> "!B64TMP!" echo IGVjaG8uDQogIGVjaG8gVW5pbnN0YWxsIGZpbmlzaGVkLiBUaGUgZm9sZGVyIHdhcyBrZXB0Og0K
  >> "!B64TMP!" echo ICBlY2hvICAgJUNEJQ0KICBlY2hvICAgWW91IGNhbiBkZWxldGUgaXQgbWFudWFsbHkgaWYgeW91
  >> "!B64TMP!" echo IG5vIGxvbmdlciBuZWVkIHRoZSBzY3JpcHRzLg0KICBlY2hvLg0KICBwYXVzZQ0KICBleGl0IC9i
  >> "!B64TMP!" echo IDANCikNCg0KY2QgL2QgIiVVU0VSUFJPRklMRSUiDQplY2hvIERlbGV0aW5nIGluc3RhbGwgZm9s
  >> "!B64TMP!" echo ZGVyOiAlfmRwMA0KcmQgL3MgL3EgIiV+ZHAwIg0KZWNoby4NCmVjaG8gVW5pbnN0YWxsIGNvbXBs
  >> "!B64TMP!" echo ZXRlLiBHb29kYnllIQ0KZWNoby4NCnBhdXNlDQpleGl0IC9iIDANCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\Uninstall.bat"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- run.sh ---
set "NEED_B64=1"
if exist "!SRC!\run.sh" (
  copy /Y "!SRC!\run.sh" "!TARGET!\run.sh" >nul 2>&1
  if exist "!TARGET!\run.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] run.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1749764691.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFN0YXJ0IHRoZSBMb2NhbCBTZWFyY2ggc3RhY2sgKEZpcmVj
  >> "!B64TMP!" echo cmF3bCArIFNlYXJYTkcpLgojIFVzZXMgUG9kbWFuIHdoZW4gaXQgaXMgaW5zdGFsbGVkLCBvdGhl
  >> "!B64TMP!" echo cndpc2UgRG9ja2VyIChzZWUgZW5naW5lLnNoOyBvdmVycmlkZQojIHdpdGggTE9DQUxfU0VBUkNI
  >> "!B64TMP!" echo X0VOR0lORT1wb2RtYW58ZG9ja2VyIG9yIHRoZSBzYW1lIGxpbmUgaW4gLmVudikuCnNldCAtdQpj
  >> "!B64TMP!" echo ZCAiJChkaXJuYW1lICIkMCIpIiB8fCBleGl0IDEKClsgLWYgIi4vZW5naW5lLnNoIiBdIHx8IHsK
  >> "!B64TMP!" echo ICBlY2hvICJbRVJST1JdIGVuZ2luZS5zaCBpcyBtaXNzaW5nIGZyb20gdGhpcyBmb2xkZXIuIFJl
  >> "!B64TMP!" echo LXJ1biBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaC4iID4mMjsgZXhpdCAxOyB9CiMgc2hlbGxjaGVj
  >> "!B64TMP!" echo ayBzb3VyY2U9ZW5naW5lLnNoCi4gLi9lbmdpbmUuc2gKbHNfcGF1c2Vfb25fZXhpdCAgICAgICAg
  >> "!B64TMP!" echo ICAjIGtlZXAgYSBsYXVuY2hlci1vcGVuZWQgd2luZG93IG9wZW4gYXQgdGhlIGVuZApsc19yZXF1
  >> "!B64TMP!" echo aXJlX2VuZ2luZSBydW5uaW5nCgppZiBbICEgLWYgIi5lbnYiIF07IHRoZW4KICBlY2hvICJbRVJS
  >> "!B64TMP!" echo T1JdIE5vIC5lbnYgZmlsZSBmb3VuZCBpbiB0aGlzIGZvbGRlci4gUnVuIGluc3RhbGwtbG9jYWwt
  >> "!B64TMP!" echo c2VhcmNoLnNoIGZpcnN0LiIgPiYyCiAgZXhpdCAxCmZpCgplY2hvICJTdGFydGluZyBMb2NhbCBT
  >> "!B64TMP!" echo ZWFyY2ggKEZpcmVjcmF3bCArIFNlYXJYTkcpIHdpdGggJEVOR0lORV9OQU1FLi4uIgokREMgdXAg
  >> "!B64TMP!" echo LWQgfHwgeyBlY2hvICJbRVJST1JdIEZhaWxlZCB0byBzdGFydC4iID4mMjsgZXhpdCAxOyB9CgpT
  >> "!B64TMP!" echo RUFSWE5HX1BPUlQ9IiQobHNfZW52X3ZhbHVlIC5lbnYgU0VBUlhOR19QT1JUKSI7IFNFQVJYTkdf
  >> "!B64TMP!" echo UE9SVD0iJHtTRUFSWE5HX1BPUlQ6LTk5OTB9IgpGSVJFQ1JBV0xfUE9SVD0iJChsc19lbnZfdmFs
  >> "!B64TMP!" echo dWUgLmVudiBGSVJFQ1JBV0xfUE9SVCkiOyBGSVJFQ1JBV0xfUE9SVD0iJHtGSVJFQ1JBV0xfUE9S
  >> "!B64TMP!" echo VDotOTk5MX0iCmVjaG8KbHNfdmVyaWZ5X3NlYXJ4bmcgIiRTRUFSWE5HX1BPUlQiIHx8IGV4aXQg
  >> "!B64TMP!" echo MQpsc19maXhfY29udGFpbmVyX3Byb3h5ICIkU0VBUlhOR19QT1JUIiB8fCBleGl0IDEKCmVjaG8K
  >> "!B64TMP!" echo ZWNobyAiTG9jYWwgU2VhcmNoIGlzIHJ1bm5pbmcuIgplY2hvICIgIFNlYXJYTkc6ICAgaHR0cDov
  >> "!B64TMP!" echo L2xvY2FsaG9zdDoke1NFQVJYTkdfUE9SVH0iCmVjaG8gIiAgRmlyZWNyYXdsOiBodHRwOi8vbG9j
  >> "!B64TMP!" echo YWxob3N0OiR7RklSRUNSQVdMX1BPUlR9IgplY2hvICJSdW4gLi9zdG9wLnNoIHRvIHN0b3AgdGhl
  >> "!B64TMP!" echo IHN0YWNrLiIK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\run.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- stop.sh ---
set "NEED_B64=1"
if exist "!SRC!\stop.sh" (
  copy /Y "!SRC!\stop.sh" "!TARGET!\stop.sh" >nul 2>&1
  if exist "!TARGET!\stop.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] stop.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3584733866.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFN0b3AgdGhlIExvY2FsIFNlYXJjaCBzdGFjayAoY29udGFp
  >> "!B64TMP!" echo bmVycyByZW1vdmVkLCBkYXRhIHByZXNlcnZlZCkuCnNldCAtdQpjZCAiJChkaXJuYW1lICIkMCIp
  >> "!B64TMP!" echo IiB8fCBleGl0IDEKClsgLWYgIi4vZW5naW5lLnNoIiBdIHx8IHsKICBlY2hvICJbRVJST1JdIGVu
  >> "!B64TMP!" echo Z2luZS5zaCBpcyBtaXNzaW5nIGZyb20gdGhpcyBmb2xkZXIuIFJlLXJ1biBpbnN0YWxsLWxvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaC5zaC4iID4mMjsgZXhpdCAxOyB9CiMgc2hlbGxjaGVjayBzb3VyY2U9ZW5naW5lLnNo
  >> "!B64TMP!" echo Ci4gLi9lbmdpbmUuc2gKbHNfcGF1c2Vfb25fZXhpdApsc19yZXF1aXJlX2VuZ2luZQoKaWYgWyAh
  >> "!B64TMP!" echo IC1mICIuZW52IiBdOyB0aGVuCiAgZWNobyAiW0VSUk9SXSBObyAuZW52IGZpbGUgZm91bmQuIE5v
  >> "!B64TMP!" echo dGhpbmcgdG8gc3RvcC4iID4mMjsgZXhpdCAxCmZpCgplY2hvICJTdG9wcGluZyBMb2NhbCBTZWFy
  >> "!B64TMP!" echo Y2ggY29udGFpbmVycyAoZGF0YSBpcyBwcmVzZXJ2ZWQpLi4uIgokREMgZG93biB8fCB7IGVjaG8g
  >> "!B64TMP!" echo IltFUlJPUl0gRmFpbGVkIHRvIHN0b3AuIiA+JjI7IGV4aXQgMTsgfQoKZWNobwplY2hvICJMb2Nh
  >> "!B64TMP!" echo bCBTZWFyY2ggc3RvcHBlZC4gRGF0YSBpcyBwcmVzZXJ2ZWQgaW4gJEVOR0lORV9OQU1FIHZvbHVt
  >> "!B64TMP!" echo ZXMuIgplY2hvICJSdW4gLi9ydW4uc2ggdG8gc3RhcnQgaXQgYWdhaW4uIgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\stop.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- update.sh ---
set "NEED_B64=1"
if exist "!SRC!\update.sh" (
  copy /Y "!SRC!\update.sh" "!TARGET!\update.sh" >nul 2>&1
  if exist "!TARGET!\update.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] update.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS960388646.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFVwZGF0ZSB0aGUgTG9jYWwgU2VhcmNoIHN0YWNrOiBwdWxs
  >> "!B64TMP!" echo IGxhdGVzdCBpbWFnZXMsIHJlY3JlYXRlIGNvbnRhaW5lcnMsCiMgYW5kIHJlLXN5bmMgdGhlIGxv
  >> "!B64TMP!" echo Y2FsLXdlYi1zZWFyY2ggYWdlbnQgc2tpbGwuIERhdGEgdm9sdW1lcyBhcmUgcHJlc2VydmVkLiBF
  >> "!B64TMP!" echo ZGl0cwojIHRvIC5lbnYgKHBvcnRzLCBMTE0pIGFyZSBhbHNvIGFwcGxpZWQuCnNldCAtdQpjZCAi
  >> "!B64TMP!" echo JChkaXJuYW1lICIkMCIpIiB8fCBleGl0IDEKClsgLWYgIi4vZW5naW5lLnNoIiBdIHx8IHsKICBl
  >> "!B64TMP!" echo Y2hvICJbRVJST1JdIGVuZ2luZS5zaCBpcyBtaXNzaW5nIGZyb20gdGhpcyBmb2xkZXIuIFJlLXJ1
  >> "!B64TMP!" echo biBpbnN0YWxsLWxvY2FsLXNlYXJjaC5zaC4iID4mMjsgZXhpdCAxOyB9CiMgc2hlbGxjaGVjayBz
  >> "!B64TMP!" echo b3VyY2U9ZW5naW5lLnNoCi4gLi9lbmdpbmUuc2gKbHNfcGF1c2Vfb25fZXhpdApsc19yZXF1aXJl
  >> "!B64TMP!" echo X2VuZ2luZSBydW5uaW5nCgppZiBbICEgLWYgIi5lbnYiIF07IHRoZW4KICBlY2hvICJbRVJST1Jd
  >> "!B64TMP!" echo IE5vIC5lbnYgZmlsZSBmb3VuZC4gUnVuIGluc3RhbGwtbG9jYWwtc2VhcmNoLnNoIGZpcnN0LiIg
  >> "!B64TMP!" echo PiYyCiAgZXhpdCAxCmZpCgplY2hvICJVcGRhdGluZyBMb2NhbCBTZWFyY2ggKHVzaW5nICRFTkdJ
  >> "!B64TMP!" echo TkVfTkFNRSkuLi4iCmVjaG8KZWNobyAiWzEvM10gUHVsbGluZyBsYXRlc3QgaW1hZ2VzLi4uIgok
  >> "!B64TMP!" echo REMgcHVsbCB8fCBlY2hvICJbV0FSTklOR10gU29tZSBpbWFnZXMgZmFpbGVkIHRvIHB1bGwuIENv
  >> "!B64TMP!" echo bnRpbnVpbmcuIgoKZWNobwplY2hvICJbMi8zXSBSZWNyZWF0aW5nIGNvbnRhaW5lcnMgd2l0aCB1
  >> "!B64TMP!" echo cGRhdGVkIGltYWdlcyAoZGF0YSBpcyBwcmVzZXJ2ZWQpLi4uIgokREMgdXAgLWQgfHwgeyBlY2hv
  >> "!B64TMP!" echo ICJbRVJST1JdIEZhaWxlZCB0byByZWNyZWF0ZSBjb250YWluZXJzLiIgPiYyOyBleGl0IDE7IH0K
  >> "!B64TMP!" echo U0VBUlhOR19QT1JUPSIkKGxzX2Vudl92YWx1ZSAuZW52IFNFQVJYTkdfUE9SVCkiOyBTRUFSWE5H
  >> "!B64TMP!" echo X1BPUlQ9IiR7U0VBUlhOR19QT1JUOi05OTkwfSIKbHNfdmVyaWZ5X3NlYXJ4bmcgIiRTRUFSWE5H
  >> "!B64TMP!" echo X1BPUlQiOyBWRVJJRllfUkM9JD8KaWYgWyAiJFZFUklGWV9SQyIgLWVxIDAgXTsgdGhlbiBsc19m
  >> "!B64TMP!" echo aXhfY29udGFpbmVyX3Byb3h5ICIkU0VBUlhOR19QT1JUIjsgVkVSSUZZX1JDPSQ/OyBmaQoKZWNo
  >> "!B64TMP!" echo bwplY2hvICJbMy8zXSBSZWZyZXNoaW5nIHRoZSBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNraWxs
  >> "!B64TMP!" echo Li4uIgppZiBbIC1mICIuL2xvY2FsLXdlYi1zZWFyY2gvU0tJTEwubWQiIF07IHRoZW4KICBTS0lM
  >> "!B64TMP!" echo TF9ESVI9IiRIT01FLy5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2giCiAgcm0gLXJmICIk
  >> "!B64TMP!" echo U0tJTExfRElSIgogIG1rZGlyIC1wICIkSE9NRS8uYWdlbnRzL3NraWxscyIKICBpZiBjcCAtciAu
  >> "!B64TMP!" echo L2xvY2FsLXdlYi1zZWFyY2ggIiRTS0lMTF9ESVIiOyB0aGVuCiAgICBwcmludGYgJyVzXG4nICIk
  >> "!B64TMP!" echo KHB3ZCkiID4gIiRTS0lMTF9ESVIvaW5zdGFsbC1kaXIudHh0IgogICAgZWNobyAiICBTa2lsbCBy
  >> "!B64TMP!" echo ZWZyZXNoZWQgYXQgJFNLSUxMX0RJUiIKICBlbHNlCiAgICBlY2hvICIgIFtXQVJOSU5HXSBDb3Vs
  >> "!B64TMP!" echo ZCBub3QgY29weSB0aGUgc2tpbGwgdG8gJFNLSUxMX0RJUi4iCiAgZmkKZWxzZQogIGVjaG8gIiAg
  >> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaCBza2lsbCBzb3VyY2Ugbm90IGZvdW5kIGluIHRoaXMgZm9sZGVyIC0g
  >> "!B64TMP!" echo c2tpcHBpbmcuIgpmaQoKZWNobwppZiBbICIkVkVSSUZZX1JDIiAtbmUgMCBdOyB0aGVuCiAgZWNo
  >> "!B64TMP!" echo byAiVXBkYXRlIGZpbmlzaGVkLCBidXQgU2VhclhORyBvciB0aGUgY29udGFpbmVycycgcHJveHkg
  >> "!B64TMP!" echo c2V0dGluZ3MgbmVlZCBhdHRlbnRpb24gLSBzZWUgdGhlIGRldGFpbHMgYWJvdmUuIiA+JjIKICBl
  >> "!B64TMP!" echo eGl0IDEKZmkKZWNobyAiVXBkYXRlIGNvbXBsZXRlLiBEYXRhIHZvbHVtZXMgd2VyZSBwcmVzZXJ2
  >> "!B64TMP!" echo ZWQuIgplY2hvICIgIC0gUG9ydCAvIExMTSBjaGFuZ2VzIGluIC5lbnYgYXJlIG5vdyBhcHBsaWVk
  >> "!B64TMP!" echo LiIKZWNobyAiICAtIFRoZSBsb2NhbC13ZWItc2VhcmNoIHNraWxsIHdhcyByZS1zeW5jZWQgZnJv
  >> "!B64TMP!" echo bSB0aGlzIGZvbGRlci4iCmVjaG8gIiAgLSBUbyB1cGRhdGUgdGhlIFNlYXJYTkcgc2V0dGluZ3Mu
  >> "!B64TMP!" echo eW1sIG9yIGRvY2tlci1jb21wb3NlLnltbCB0ZW1wbGF0ZSwiCmVjaG8gIiAgICByZS1ydW4gaW5z
  >> "!B64TMP!" echo dGFsbC1sb2NhbC1zZWFyY2guc2ggKGl0IGJhY2tzIHVwIHlvdXIgY3VycmVudCAuZW52KS4iCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\update.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- uninstall.sh ---
set "NEED_B64=1"
if exist "!SRC!\uninstall.sh" (
  copy /Y "!SRC!\uninstall.sh" "!TARGET!\uninstall.sh" >nul 2>&1
  if exist "!TARGET!\uninstall.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] uninstall.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3708239055.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgYmFzaAojIFVuaW5zdGFsbCB0aGUgTG9jYWwgU2VhcmNoIHN0YWNrLgoj
  >> "!B64TMP!" echo ICAgLSBzdG9wcyAmIHJlbW92ZXMgY29udGFpbmVycwojICAgLSByZW1vdmVzIGNvbnRhaW5lciB2
  >> "!B64TMP!" echo b2x1bWVzIChGaXJlY3Jhd2wgam9iIHN0YXRlLCByZWRpcywgcmFiYml0bXEsIHBvc3RncmVzKQoj
  >> "!B64TMP!" echo ICAgLSByZW1vdmVzIHRoZSBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNraWxsICh+Ly5hZ2VudHMv
  >> "!B64TMP!" echo c2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gpCiMgICAtIG9wdGlvbmFsbHkgZGVsZXRlcyB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbCBmb2xkZXIKc2V0IC11CmNkICIkKGRpcm5hbWUgIiQwIikiIHx8IGV4aXQgMQpsb3dlcigp
  >> "!B64TMP!" echo IHsgcHJpbnRmICclcycgIiQxIiB8IHRyICdbOnVwcGVyOl0nICdbOmxvd2VyOl0nOyB9ICAjIGJh
  >> "!B64TMP!" echo c2gtMy4yIChtYWNPUykgc2FmZQoKWyAtZiAiLi9lbmdpbmUuc2giIF0gfHwgewogIGVjaG8gIltF
  >> "!B64TMP!" echo UlJPUl0gZW5naW5lLnNoIGlzIG1pc3NpbmcgZnJvbSB0aGlzIGZvbGRlci4gUmUtcnVuIGluc3Rh
  >> "!B64TMP!" echo bGwtbG9jYWwtc2VhcmNoLnNoLiIgPiYyOyBleGl0IDE7IH0KIyBzaGVsbGNoZWNrIHNvdXJjZT1l
  >> "!B64TMP!" echo bmdpbmUuc2gKLiAuL2VuZ2luZS5zaApsc19wYXVzZV9vbl9leGl0CmlmICEgbHNfc2VsZWN0X2Vu
  >> "!B64TMP!" echo Z2luZSAiLi8uZW52IjsgdGhlbgogIGVjaG8gIiAgWW91IGNhbiBkZWxldGUgdGhpcyBmb2xkZXIg
  >> "!B64TMP!" echo bWFudWFsbHkuIiA+JjIKICBleGl0IDEKZmkKbHNfc2VsZWN0X2NvbXBvc2UgfHwgZXhpdCAxCmxz
  >> "!B64TMP!" echo X2Vuc3VyZV9wb2RtYW5fc29ja2V0IHx8IGVjaG8gIiAgWyFdIFBvZG1hbidzIEFQSSBzb2NrZXQg
  >> "!B64TMP!" echo aXMgbm90IGFjdGl2ZSAtIGlmIGNvbXBvc2UgZmFpbHMsIHJ1bjogc3lzdGVtY3RsIC0tdXNlciBl
  >> "!B64TMP!" echo bmFibGUgLS1ub3cgcG9kbWFuLnNvY2tldCIKCmlmIFsgISAtZiAiLmVudiIgXTsgdGhlbgogIGVj
  >> "!B64TMP!" echo aG8gIltFUlJPUl0gTm8gLmVudiBmaWxlIGZvdW5kLiBOb3RoaW5nIHRvIHVuaW5zdGFsbC4iID4m
  >> "!B64TMP!" echo MjsgZXhpdCAxCmZpCgpjYXQgPDwnTVNHJwo9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0KICBVbmluc3RhbGwgTG9jYWwgU2VhcmNoCj09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PQpUaGlzIHdpbGw6CiAgMS4gU3RvcCBhbmQgcmVtb3ZlIGFsbCBMb2NhbCBTZWFyY2ggY29udGFp
  >> "!B64TMP!" echo bmVycy4KICAyLiBSZW1vdmUgdGhlIGNvbnRhaW5lciBWT0xVTUVTIChGaXJlY3Jhd2wgam9iIHN0
  >> "!B64TMP!" echo YXRlLCByZWRpcyBjYWNoZSwKICAgICByYWJiaXRtcS9wb3N0Z3JlcyBkYXRhKS4gVGhpcyBkZWxl
  >> "!B64TMP!" echo dGVzIGFsbCBzdG9yZWQgZGF0YS4KICAzLiBSZW1vdmUgdGhlIGxvY2FsLXdlYi1zZWFyY2ggYWdl
  >> "!B64TMP!" echo bnQgc2tpbGwgZnJvbQogICAgIH4vLmFnZW50cy9za2lsbHMvbG9jYWwtd2ViLXNlYXJjaAogIDQu
  >> "!B64TMP!" echo IChPcHRpb25hbCkgRGVsZXRlIHRoZSBpbnN0YWxsIGZvbGRlciBhbmQgYWxsIGl0cyBmaWxlcy4K
  >> "!B64TMP!" echo CiAgUHVsbGVkIGltYWdlcyBhcmUgTk9UIHJlbW92ZWQgKHVzZSAncG9kbWFuIGltYWdlIHBydW5l
  >> "!B64TMP!" echo JyBvcgogICdkb2NrZXIgaW1hZ2UgcHJ1bmUnIHRvIHJlY2xhaW0gdGhhdCBkaXNrIHNwYWNlIHNl
  >> "!B64TMP!" echo cGFyYXRlbHkpLgpNU0cKZWNobwpwcmludGYgIkNvbnRpbnVlIHdpdGggdW5pbnN0YWxsPyBbeS9O
  >> "!B64TMP!" echo XTogIgpyZWFkIC1yIENPTkZJUk0KaWYgWyAiJChsb3dlciAiJENPTkZJUk0iKSIgIT0gInkiIF07
  >> "!B64TMP!" echo IHRoZW4gZWNobyAiVW5pbnN0YWxsIGNhbmNlbGxlZC4iOyBleGl0IDA7IGZpCgplY2hvCmVjaG8g
  >> "!B64TMP!" echo IlN0b3BwaW5nIGFuZCByZW1vdmluZyBjb250YWluZXJzICsgdm9sdW1lcy4uLiIKJERDIGRvd24g
  >> "!B64TMP!" echo LXYgLS1yZW1vdmUtb3JwaGFucyB8fCBlY2hvICJbV0FSTklOR10gZG9ja2VyIGNvbXBvc2UgZG93
  >> "!B64TMP!" echo biByZXBvcnRlZCBlcnJvcnMuIgoKZWNobwplY2hvICJDb250YWluZXJzIGFuZCB2b2x1bWVzIHJl
  >> "!B64TMP!" echo bW92ZWQuIgplY2hvCmVjaG8gIlJlbW92aW5nIHRoZSBsb2NhbC13ZWItc2VhcmNoIGFnZW50IHNr
  >> "!B64TMP!" echo aWxsLi4uIgpTS0lMTF9ESVI9IiRIT01FLy5hZ2VudHMvc2tpbGxzL2xvY2FsLXdlYi1zZWFyY2gi
  >> "!B64TMP!" echo CmlmIFsgLWQgIiRTS0lMTF9ESVIiIF07IHRoZW4KICBybSAtcmYgIiRTS0lMTF9ESVIiCiAgZWNo
  >> "!B64TMP!" echo byAiICBSZW1vdmVkICRTS0lMTF9ESVIiCmVsc2UKICBlY2hvICIgIFNraWxsIG5vdCBmb3VuZCAo
  >> "!B64TMP!" echo YWxyZWFkeSByZW1vdmVkKSAtIG5vdGhpbmcgdG8gZG8uIgpmaQplY2hvCnByaW50ZiAiQWxzbyBk
  >> "!B64TMP!" echo ZWxldGUgdGhlIGluc3RhbGwgZm9sZGVyIGFuZCBBTEwgaXRzIGZpbGVzPyBbeS9OXTogIgpyZWFk
  >> "!B64TMP!" echo IC1yIERFTEZJTEVTCmlmIFsgIiQobG93ZXIgIiRERUxGSUxFUyIpIiAhPSAieSIgXTsgdGhlbgog
  >> "!B64TMP!" echo IGVjaG8KICBlY2hvICJVbmluc3RhbGwgZmluaXNoZWQuIFRoZSBmb2xkZXIgd2FzIGtlcHQ6Igog
  >> "!B64TMP!" echo IGVjaG8gIiAgJChwd2QpIgogIGVjaG8gIiAgWW91IGNhbiBkZWxldGUgaXQgbWFudWFsbHkgaWYg
  >> "!B64TMP!" echo eW91IG5vIGxvbmdlciBuZWVkIHRoZSBzY3JpcHRzLiIKICBleGl0IDAKZmkKClRBUkdFVD0iJChw
  >> "!B64TMP!" echo d2QpIgpjZCAiJEhPTUUiCmVjaG8gIkRlbGV0aW5nIGluc3RhbGwgZm9sZGVyOiAkVEFSR0VUIgpy
  >> "!B64TMP!" echo bSAtcmYgIiRUQVJHRVQiCmVjaG8KZWNobyAiVW5pbnN0YWxsIGNvbXBsZXRlLiBHb29kYnllISIK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\uninstall.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- engine.sh ---
set "NEED_B64=1"
if exist "!SRC!\engine.sh" (
  copy /Y "!SRC!\engine.sh" "!TARGET!\engine.sh" >nul 2>&1
  if exist "!TARGET!\engine.sh" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] engine.sh  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS186919069.b64"
  > "!B64TMP!" echo IyA9PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PQojICBlbmdpbmUuc2ggLSBjb250YWluZXItZW5naW5lIGRl
  >> "!B64TMP!" echo dGVjdGlvbiBmb3IgdGhlIExvY2FsIFNlYXJjaCBzaGVsbCBzY3JpcHRzCiMgPT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT0KIyAgU291cmNlZCBieSBydW4uc2ggLyBzdG9wLnNoIC8gdXBkYXRlLnNoIC8gdW5p
  >> "!B64TMP!" echo bnN0YWxsLnNoLCBhbmQgaW5saW5lZCB2ZXJiYXRpbQojICBpbnRvIGluc3RhbGwtbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoLnNoIGJ5IGdlbl9pbnN0YWxsZXJzLnB5IC0gc28gdGhlcmUgaXMgZXhhY3RseSBPTkUKIyAg
  >> "!B64TMP!" echo Y29weSBvZiB0aGlzIGxvZ2ljLiBJdCBpcyBhIGxpYnJhcnk6IGl0IGlzIG5vdCBtZWFudCB0byBi
  >> "!B64TMP!" echo ZSBydW4gb24gaXRzIG93bi4KIwojICBXaGljaCBlbmdpbmUgaXMgdXNlZCAoZmlyc3QgbWF0Y2gg
  >> "!B64TMP!" echo d2lucyk6CiMgICAgMS4gTE9DQUxfU0VBUkNIX0VOR0lORT1wb2RtYW58ZG9ja2VyIGluIHRoZSBl
  >> "!B64TMP!" echo bnZpcm9ubWVudCAgIChmb3JjZWQpCiMgICAgMi4gTE9DQUxfU0VBUkNIX0VOR0lORT1wb2RtYW58
  >> "!B64TMP!" echo ZG9ja2VyIGluIHRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYKIyAgICAgICAodGhlIGluc3RhbGxl
  >> "!B64TMP!" echo ciByZWNvcmRzIGl0cyBjaG9pY2UgdGhlcmUsIHNvIHJ1bi5zaCAvIHVwZGF0ZS5zaCBrZWVwCiMg
  >> "!B64TMP!" echo ICAgICAgIHVzaW5nIHRoZSBlbmdpbmUgdGhhdCBjcmVhdGVkIHRoZSBjb250YWluZXJzKQojICAg
  >> "!B64TMP!" echo IDMuIGF1dG8tZGV0ZWN0OiBQb2RtYW4gd2hlbiBpdCBpcyBpbnN0YWxsZWQsIG90aGVyd2lzZSBE
  >> "!B64TMP!" echo b2NrZXIKIyAgICAgICAoaWYgYm90aCBhcmUgaW5zdGFsbGVkLCBQb2RtYW4gd2lucykKIwojICBG
  >> "!B64TMP!" echo dW5jdGlvbnMgKGFsbCBiYXNoIDMuMiBzYWZlKToKIyAgICBsc19zZWxlY3RfZW5naW5lIFtFTlZG
  >> "!B64TMP!" echo SUxFXSAgc2V0cyBFTkdJTkUgKHBvZG1hbnxkb2NrZXIpLCBFTkdJTkVfTkFNRSwgRU5HSU5FX0FV
  >> "!B64TMP!" echo VE8KIyAgICBsc19lbmdpbmVfcnVubmluZyAgICAgICAgICAgMCB3aGVuIHRoZSBzZWxlY3RlZCBl
  >> "!B64TMP!" echo bmdpbmUgYW5zd2VycwojICAgIGxzX3N0YXJ0X2VuZ2luZSAgICAgICAgICAgICBiZXN0LWVmZm9y
  >> "!B64TMP!" echo dCBsYXVuY2ggb2YgYSBzdG9wcGVkIGVuZ2luZQojICAgIGxzX2ZhbGxiYWNrX2VuZ2luZSAgICAg
  >> "!B64TMP!" echo ICAgICBhdXRvLXBpY2tlZCBQb2RtYW4gdW51c2FibGUgKyBEb2NrZXIgcnVubmluZyAtPiBEb2Nr
  >> "!B64TMP!" echo ZXIKIyAgICBsc19lbmdpbmVfaGludCAgICAgICAgICAgICAgcHJpbnRzICJob3cgdG8gc3RhcnQg
  >> "!B64TMP!" echo aXQgeW91cnNlbGYiIGhlbHAKIyAgICBsc19zZWxlY3RfY29tcG9zZSAgICAgICAgICAgc2V0cyBE
  >> "!B64TMP!" echo QyAoZS5nLiAicG9kbWFuIGNvbXBvc2UiLCAiZG9ja2VyIGNvbXBvc2UiKQojICAgIGxzX2Vuc3Vy
  >> "!B64TMP!" echo ZV9wb2RtYW5fc29ja2V0ICAgICBzdGFydHMgUG9kbWFuJ3MgQVBJIHNvY2tldCAobmVlZGVkIGJ5
  >> "!B64TMP!" echo IGRvY2tlci1jb21wb3NlKQojICAgIGxzX3BsYXRmb3JtX2VudiAgICAgICAgICAgICBzZXRzIExT
  >> "!B64TMP!" echo X01PVU5UX09QVFMgLyBMU19GT1JDRV9PV05FUlNISVAgZm9yIC5lbnYKIyAgICBsc192ZXJpZnlf
  >> "!B64TMP!" echo c2VhcnhuZyBQT1JUICAgICAgd2FpdHMgdW50aWwgU2VhclhORyBhbnN3ZXJzOyBkaWFnbm9zZXMg
  >> "!B64TMP!" echo aWYgaXQgZG9lcyBub3QKIyAgICBsc19maXhfY29udGFpbmVyX3Byb3h5IFBPUlQgIGJsYW5rcyBs
  >> "!B64TMP!" echo b29wYmFjayBwcm94eSB2YXJpYWJsZXMgdGhlIGNvbnRhaW5lcnMgaW5oZXJpdGVkIGZyb20gdGhl
  >> "!B64TMP!" echo IHNoZWxsCiMgICAgbHNfcGF1c2Vfb25fZXhpdCAgICAgICAgICAgIGtlZXBzIGEgbGF1bmNoZXIt
  >> "!B64TMP!" echo b3BlbmVkIHRlcm1pbmFsIHdpbmRvdyBvcGVuIGF0IHRoZSBlbmQKIyAgICBsc19yZXF1aXJlX2Vu
  >> "!B64TMP!" echo Z2luZSBbcnVubmluZ10gc2VsZWN0ICsgY29tcG9zZSAoKyBydW5uaW5nIGNoZWNrKTsgZXhpdHMg
  >> "!B64TMP!" echo b24gZmFpbHVyZQojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
  >> "!B64TMP!" echo PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09Cgpsc19sb3dlcigpIHsgcHJpbnRmICcl
  >> "!B64TMP!" echo cycgIiQxIiB8IHRyICdbOnVwcGVyOl0nICdbOmxvd2VyOl0nOyB9CmxzX2VycigpICAgeyBpZiB0
  >> "!B64TMP!" echo eXBlIGVyciA+L2Rldi9udWxsIDI+JjE7IHRoZW4gZXJyICIkMSI7IGVsc2UgcHJpbnRmICdbRVJS
  >> "!B64TMP!" echo T1JdICVzXG4nICIkMSIgPiYyOyBmaTsgfQpsc19zYXkoKSAgIHsgaWYgdHlwZSBzYXkgPi9kZXYv
  >> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuIHNheSAiJDEiOyBlbHNlIHByaW50ZiAnJXNcbicgIiQxIjsgZmk7IH0K
  >> "!B64TMP!" echo bHNfb2soKSAgICB7IGlmIHR5cGUgb2sgID4vZGV2L251bGwgMj4mMTsgdGhlbiBvayAgIiQxIjsg
  >> "!B64TMP!" echo ZWxzZSBwcmludGYgJ1tPS10gJXNcbicgIiQxIjsgZmk7IH0KCiMgbHNfZW52X3ZhbHVlIEZJTEUg
  >> "!B64TMP!" echo S0VZIC0+IHRoZSBsYXN0IEtFWT12YWx1ZSBsaW5lIG9mIEZJTEUgKHF1b3RlcyAvIENSIHN0cmlw
  >> "!B64TMP!" echo cGVkKQpsc19lbnZfdmFsdWUoKSB7CiAgWyAtZiAiJDEiIF0gfHwgcmV0dXJuIDAKICBncmVwIC1F
  >> "!B64TMP!" echo ICJeJDI9IiAiJDEiIDI+L2Rldi9udWxsIHwgdGFpbCAtbiAxIHwgY3V0IC1kPSAtZjItIHwgdHIg
  >> "!B64TMP!" echo LWQgJ1xyIicgfCB0ciAtZCAiJyIKfQoKbHNfaW5zdGFsbF9oaW50KCkgewogIGxzX3NheSAiIgog
  >> "!B64TMP!" echo IGxzX3NheSAiSW5zdGFsbCBvbmUgb2YgdGhlbSwgdGhlbiByZS1ydW46IgogIGxzX3NheSAiICBQ
  >> "!B64TMP!" echo b2RtYW4gKHByZWZlcnJlZCB3aGVuIGJvdGggYXJlIGluc3RhbGxlZCk6IgogIGxzX3NheSAiICAg
  >> "!B64TMP!" echo IEZlZG9yYSAvIFJIRUw6ICAgIHN1ZG8gZG5mIGluc3RhbGwgcG9kbWFuIGRvY2tlci1jb21wb3Nl
  >> "!B64TMP!" echo IgogIGxzX3NheSAiICAgIERlYmlhbiAvIFVidW50dTogIHN1ZG8gYXB0IGluc3RhbGwgcG9kbWFu
  >> "!B64TMP!" echo IGRvY2tlci1jb21wb3NlLXYyIgogIGxzX3NheSAiICAgIG1hY09TOiAgICAgICAgICAgIGJyZXcg
  >> "!B64TMP!" echo aW5zdGFsbCBwb2RtYW4gZG9ja2VyLWNvbXBvc2UgJiYgcG9kbWFuIG1hY2hpbmUgaW5pdCIKICBs
  >> "!B64TMP!" echo c19zYXkgIiAgRG9ja2VyOiIKICBsc19zYXkgIiAgICBMaW51eDogIGh0dHBzOi8vZG9jcy5kb2Nr
  >> "!B64TMP!" echo ZXIuY29tL2VuZ2luZS9pbnN0YWxsLyIKICBsc19zYXkgIiAgICBtYWNPUzogIGh0dHBzOi8vd3d3
  >> "!B64TMP!" echo LmRvY2tlci5jb20vcHJvZHVjdHMvZG9ja2VyLWRlc2t0b3AvIgp9Cgpsc19zZWxlY3RfZW5naW5l
  >> "!B64TMP!" echo KCkgewogIGxvY2FsIHdhbnQ9IiIgc3JjPSIiIGhhdmVfcD0wIGhhdmVfZD0wCiAgRU5HSU5FPSIi
  >> "!B64TMP!" echo OyBFTkdJTkVfTkFNRT0iIjsgRU5HSU5FX0FVVE89MAogIGNvbW1hbmQgLXYgcG9kbWFuID4vZGV2
  >> "!B64TMP!" echo L251bGwgMj4mMSAmJiBoYXZlX3A9MQogIGNvbW1hbmQgLXYgZG9ja2VyID4vZGV2L251bGwgMj4m
  >> "!B64TMP!" echo MSAmJiBoYXZlX2Q9MQoKICB3YW50PSIkKGxzX2xvd2VyICIke0xPQ0FMX1NFQVJDSF9FTkdJTkU6
  >> "!B64TMP!" echo LX0iKSIKICBpZiBbIC1uICIkd2FudCIgXTsgdGhlbgogICAgc3JjPSJMT0NBTF9TRUFSQ0hfRU5H
  >> "!B64TMP!" echo SU5FIgogIGVsaWYgWyAtbiAiJHsxOi19IiBdOyB0aGVuCiAgICB3YW50PSIkKGxzX2xvd2VyICIk
  >> "!B64TMP!" echo KGxzX2Vudl92YWx1ZSAiJDEiIExPQ0FMX1NFQVJDSF9FTkdJTkUpIikiCiAgICBzcmM9Ii5lbnYi
  >> "!B64TMP!" echo CiAgZmkKICBjYXNlICIkd2FudCIgaW4KICAgICIifGF1dG8pIHdhbnQ9IiIgOzsKICAgIHBvZG1h
  >> "!B64TMP!" echo bnxkb2NrZXIpIDs7CiAgICAqKSBsc19lcnIgIiRzcmMgbXVzdCBiZSAncG9kbWFuJyBvciAnZG9j
  >> "!B64TMP!" echo a2VyJyAoZ290ICckd2FudCcpLiI7IHJldHVybiAxIDs7CiAgZXNhYwoKICBpZiBbIC1uICIkd2Fu
  >> "!B64TMP!" echo dCIgXTsgdGhlbgogICAgaWYgWyAiJHdhbnQiID0gInBvZG1hbiIgXSAmJiBbICIkaGF2ZV9wIiA9
  >> "!B64TMP!" echo IDEgXTsgdGhlbiBFTkdJTkU9cG9kbWFuOyBFTkdJTkVfTkFNRT1Qb2RtYW47IHJldHVybiAwOyBm
  >> "!B64TMP!" echo aQogICAgaWYgWyAiJHdhbnQiID0gImRvY2tlciIgXSAmJiBbICIkaGF2ZV9kIiA9IDEgXTsgdGhl
  >> "!B64TMP!" echo biBFTkdJTkU9ZG9ja2VyOyBFTkdJTkVfTkFNRT1Eb2NrZXI7IHJldHVybiAwOyBmaQogICAgaWYg
  >> "!B64TMP!" echo WyAiJHNyYyIgPSAiTE9DQUxfU0VBUkNIX0VOR0lORSIgXTsgdGhlbgogICAgICBsc19lcnIgIkxP
  >> "!B64TMP!" echo Q0FMX1NFQVJDSF9FTkdJTkU9JHdhbnQsIGJ1dCAnJHdhbnQnIHdhcyBub3QgZm91bmQgb24geW91
  >> "!B64TMP!" echo ciBQQVRILiIKICAgICAgcmV0dXJuIDEKICAgIGZpCiAgICBsc19zYXkgIiAgWyFdIC5lbnYgYXNr
  >> "!B64TMP!" echo cyBmb3IgJyR3YW50Jywgd2hpY2ggaXMgbm90IGluc3RhbGxlZCAtIGF1dG8tZGV0ZWN0aW5nIGlu
  >> "!B64TMP!" echo c3RlYWQuIgogIGZpCgogIEVOR0lORV9BVVRPPTEKICBpZiAgIFsgIiRoYXZlX3AiID0gMSBdOyB0
  >> "!B64TMP!" echo aGVuIEVOR0lORT1wb2RtYW47IEVOR0lORV9OQU1FPVBvZG1hbgogIGVsaWYgWyAiJGhhdmVfZCIg
  >> "!B64TMP!" echo PSAxIF07IHRoZW4gRU5HSU5FPWRvY2tlcjsgRU5HSU5FX05BTUU9RG9ja2VyCiAgZWxzZQogICAg
  >> "!B64TMP!" echo bHNfZXJyICJOZWl0aGVyIFBvZG1hbiBub3IgRG9ja2VyIHdhcyBmb3VuZCBvbiB5b3VyIFBBVEgu
  >> "!B64TMP!" echo IgogICAgbHNfaW5zdGFsbF9oaW50CiAgICByZXR1cm4gMQogIGZpCiAgcmV0dXJuIDAKfQoKbHNf
  >> "!B64TMP!" echo ZW5naW5lX3J1bm5pbmcoKSB7ICIkRU5HSU5FIiBpbmZvID4vZGV2L251bGwgMj4mMTsgfQoKIyBB
  >> "!B64TMP!" echo dXRvLXBpY2tlZCBQb2RtYW4gY2Fubm90IHJ1biBidXQgRG9ja2VyIGFuc3dlcnM6IHVzZSBEb2Nr
  >> "!B64TMP!" echo ZXIgKHdpdGggYSBub3RpY2UKIyBmcm9tIHRoZSBjYWxsZXIpLiBOZXZlciBvdmVycmlkZXMgYW4g
  >> "!B64TMP!" echo ZXhwbGljaXQgTE9DQUxfU0VBUkNIX0VOR0lORSAvIC5lbnYgY2hvaWNlLgpsc19mYWxsYmFja19l
  >> "!B64TMP!" echo bmdpbmUoKSB7CiAgWyAiJHtFTkdJTkVfQVVUTzotMH0iID0gMSBdICYmIFsgIiRFTkdJTkUiID0g
  >> "!B64TMP!" echo InBvZG1hbiIgXSB8fCByZXR1cm4gMQogIGNvbW1hbmQgLXYgZG9ja2VyID4vZGV2L251bGwgMj4m
  >> "!B64TMP!" echo MSB8fCByZXR1cm4gMQogIGRvY2tlciBpbmZvID4vZGV2L251bGwgMj4mMSB8fCByZXR1cm4gMQog
  >> "!B64TMP!" echo IEVOR0lORT1kb2NrZXI7IEVOR0lORV9OQU1FPURvY2tlcgogIHJldHVybiAwCn0KCiMgTGF1bmNo
  >> "!B64TMP!" echo IGEgc3RvcHBlZCBlbmdpbmUuIFJldHVybnMgMCB3aGVuIGEgc3RhcnQgd2FzIGlzc3VlZCAodGhl
  >> "!B64TMP!" echo IGNhbGxlciB3YWl0cwojIGZvciBpdCB3aXRoIGxzX2VuZ2luZV9ydW5uaW5nKSwgMSB3aGVuIHRo
  >> "!B64TMP!" echo ZXJlIGlzIG5vdGhpbmcgaXQgY2FuIHN0YXJ0Lgpsc19zdGFydF9lbmdpbmUoKSB7CiAgbG9jYWwg
  >> "!B64TMP!" echo dW5pdAogIGlmIFsgIiRFTkdJTkUiID0gInBvZG1hbiIgXTsgdGhlbgogICAgIyBMaW51eDogcm9v
  >> "!B64TMP!" echo dGxlc3MgUG9kbWFuIGhhcyBubyBkYWVtb24sIHNvIHRoZXJlIGlzIG5vdGhpbmcgdG8gc3RhcnQu
  >> "!B64TMP!" echo CiAgICAjIG1hY09TOiBQb2RtYW4gcnVucyBpbiBhIFZNICgicG9kbWFuIG1hY2hpbmUiKSB0aGF0
  >> "!B64TMP!" echo IGhhcyB0byBiZSBzdGFydGVkLgogICAgaWYgWyAiJCh1bmFtZSkiID0gIkRhcndpbiIgXTsgdGhl
  >> "!B64TMP!" echo bgogICAgICBbIC1uICIkKHBvZG1hbiBtYWNoaW5lIGxpc3QgLS1mb3JtYXQgJ3t7Lk5hbWV9fScg
  >> "!B64TMP!" echo Mj4vZGV2L251bGwpIiBdIHx8IHJldHVybiAxCiAgICAgICggcG9kbWFuIG1hY2hpbmUgc3RhcnQg
  >> "!B64TMP!" echo Pi9kZXYvbnVsbCAyPiYxICYgKQogICAgICByZXR1cm4gMAogICAgZmkKICAgIHJldHVybiAxCiAg
  >> "!B64TMP!" echo ZmkKICBpZiBbICIkKHVuYW1lKSIgPSAiRGFyd2luIiBdOyB0aGVuCiAgICAjIG1hY09TOiBsYXVu
  >> "!B64TMP!" echo Y2ggRG9ja2VyIERlc2t0b3AgaWYgaXQgaXMgaW5zdGFsbGVkCiAgICBpZiBjb21tYW5kIC12IG9w
  >> "!B64TMP!" echo ZW4gPi9kZXYvbnVsbCAyPiYxIFwKICAgICAgICYmIHsgWyAtZCAiL0FwcGxpY2F0aW9ucy9Eb2Nr
  >> "!B64TMP!" echo ZXIuYXBwIiBdIHx8IFsgLWQgIiRIT01FL0FwcGxpY2F0aW9ucy9Eb2NrZXIuYXBwIiBdOyB9OyB0
  >> "!B64TMP!" echo aGVuCiAgICAgIG9wZW4gLWEgRG9ja2VyID4vZGV2L251bGwgMj4mMSAmJiByZXR1cm4gMAogICAg
  >> "!B64TMP!" echo ZmkKICAgIHJldHVybiAxCiAgZmkKICAjIExpbnV4OiBzeXN0ZW1kIHVuaXRzIChEb2NrZXIgRGVz
  >> "!B64TMP!" echo a3RvcCB1c2VzIGRvY2tlci1kZXNrdG9wLCB0aGUgY2xhc3NpYwogICMgZW5naW5lIHVzZXMgZG9j
  >> "!B64TMP!" echo a2VyKSwgdGhlbiBzZXJ2aWNlKDEpLiBOb24taW50ZXJhY3RpdmUgc3VkbyBvbmx5IC0gYW4KICAj
  >> "!B64TMP!" echo IGluc3RhbGxlciBuZXZlciBwcm9tcHRzIGZvciBhIHBhc3N3b3JkLgogIGlmIGNvbW1hbmQgLXYg
  >> "!B64TMP!" echo c3lzdGVtY3RsID4vZGV2L251bGwgMj4mMTsgdGhlbgogICAgZm9yIHVuaXQgaW4gZG9ja2VyLWRl
  >> "!B64TMP!" echo c2t0b3AgZG9ja2VyOyBkbwogICAgICBpZiBzeXN0ZW1jdGwgc3RhcnQgIiR1bml0IiA+L2Rldi9u
  >> "!B64TMP!" echo dWxsIDI+JjE7IHRoZW4gcmV0dXJuIDA7IGZpCiAgICAgIGlmIGNvbW1hbmQgLXYgc3VkbyA+L2Rl
  >> "!B64TMP!" echo di9udWxsIDI+JjEgXAogICAgICAgICAmJiBzdWRvIC1uIHN5c3RlbWN0bCBzdGFydCAiJHVuaXQi
  >> "!B64TMP!" echo ID4vZGV2L251bGwgMj4mMTsgdGhlbgogICAgICAgIHJldHVybiAwCiAgICAgIGZpCiAgICBkb25l
  >> "!B64TMP!" echo CiAgZmkKICBpZiBjb21tYW5kIC12IHNlcnZpY2UgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICBp
  >> "!B64TMP!" echo ZiBzZXJ2aWNlIGRvY2tlciBzdGFydCA+L2Rldi9udWxsIDI+JjE7IHRoZW4gcmV0dXJuIDAKICAg
  >> "!B64TMP!" echo IGVsaWYgY29tbWFuZCAtdiBzdWRvID4vZGV2L251bGwgMj4mMSBcCiAgICAgICAgICYmIHN1ZG8g
  >> "!B64TMP!" echo LW4gc2VydmljZSBkb2NrZXIgc3RhcnQgPi9kZXYvbnVsbCAyPiYxOyB0aGVuCiAgICAgIHJldHVy
  >> "!B64TMP!" echo biAwCiAgICBmaQogIGZpCiAgcmV0dXJuIDEKfQoKbHNfZW5naW5lX2hpbnQoKSB7CiAgaWYgWyAi
  >> "!B64TMP!" echo JEVOR0lORSIgPSAicG9kbWFuIiBdOyB0aGVuCiAgICBsc19zYXkgIiAgUnVuICdwb2RtYW4gaW5m
  >> "!B64TMP!" echo bycgdG8gc2VlIHdoeSBQb2RtYW4gZG9lcyBub3QgYW5zd2VyLiIKICAgIGxzX3NheSAiICAocm9v
  >> "!B64TMP!" echo dGxlc3MgUG9kbWFuIG5lZWRzIGEgbm9ybWFsIGxvZ2luIHNlc3Npb24gYW5kIHN1YnVpZC9zdWJn
  >> "!B64TMP!" echo aWQgZW50cmllcykiCiAgICBsc19zYXkgIiAgbWFjT1M6ICBwb2RtYW4gbWFjaGluZSBpbml0ICYm
  >> "!B64TMP!" echo IHBvZG1hbiBtYWNoaW5lIHN0YXJ0IgogIGVsc2UKICAgIGxzX3NheSAiICBMaW51eDogIHN1ZG8g
  >> "!B64TMP!" echo c3lzdGVtY3RsIHN0YXJ0IGRvY2tlciAgICAob3IgbGF1bmNoIERvY2tlciBEZXNrdG9wKSIKICAg
  >> "!B64TMP!" echo IGxzX3NheSAiICAgICAgICAgIHBlcm1pc3Npb24gZGVuaWVkIGZyb20gZG9ja2VyPyBhZGQgeW91
  >> "!B64TMP!" echo cnNlbGYgdG8gdGhlIGRvY2tlciIKICAgIGxzX3NheSAiICAgICAgICAgIGdyb3VwOiAgc3VkbyB1
  >> "!B64TMP!" echo c2VybW9kIC1hRyBkb2NrZXIgJHtVU0VSOi15b3VydXNlcn0gIChsb2cgb3V0IGFuZCBiYWNrIGlu
  >> "!B64TMP!" echo KSIKICAgIGxzX3NheSAiICBtYWNPUzogIG9wZW4gLWEgRG9ja2VyIgogIGZpCn0KCmxzX3NlbGVj
  >> "!B64TMP!" echo dF9jb21wb3NlKCkgewogIERDPSIiCiAgaWYgWyAiJEVOR0lORSIgPSAicG9kbWFuIiBdOyB0aGVu
  >> "!B64TMP!" echo CiAgICBpZiBwb2RtYW4gY29tcG9zZSB2ZXJzaW9uID4vZGV2L251bGwgMj4mMTsgdGhlbiBEQz0i
  >> "!B64TMP!" echo cG9kbWFuIGNvbXBvc2UiCiAgICBlbGlmIGNvbW1hbmQgLXYgcG9kbWFuLWNvbXBvc2UgPi9kZXYv
  >> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuIERDPSJwb2RtYW4tY29tcG9zZSIKICAgIGVsc2UKICAgICAgbHNfZXJy
  >> "!B64TMP!" echo ICJObyBjb21wb3NlIHByb3ZpZGVyIHdhcyBmb3VuZCBmb3IgUG9kbWFuLiIKICAgICAgbHNfc2F5
  >> "!B64TMP!" echo ICIgIEluc3RhbGwgb25lIChDb21wb3NlIHYyICdkb2NrZXItY29tcG9zZScgaXMgdGhlIG1vc3Qg
  >> "!B64TMP!" echo Y29tcGF0aWJsZSk6IgogICAgICBsc19zYXkgIiAgICBGZWRvcmEgLyBSSEVMOiAgICBzdWRvIGRu
  >> "!B64TMP!" echo ZiBpbnN0YWxsIGRvY2tlci1jb21wb3NlICAgICAob3I6IHBvZG1hbi1jb21wb3NlKSIKICAgICAg
  >> "!B64TMP!" echo bHNfc2F5ICIgICAgRGViaWFuIC8gVWJ1bnR1OiAgc3VkbyBhcHQgaW5zdGFsbCBkb2NrZXItY29t
  >> "!B64TMP!" echo cG9zZS12MiAgKG9yOiBwb2RtYW4tY29tcG9zZSkiCiAgICAgIGxzX3NheSAiICAgIG1hY09TOiAg
  >> "!B64TMP!" echo ICAgICAgICAgIGJyZXcgaW5zdGFsbCBkb2NrZXItY29tcG9zZSIKICAgICAgcmV0dXJuIDEKICAg
  >> "!B64TMP!" echo IGZpCiAgICAjICdwb2RtYW4gY29tcG9zZScgcHJpbnRzIGEgcHJvdmlkZXIgYmFubmVyIG9uIGV2
  >> "!B64TMP!" echo ZXJ5IGNhbGwgaW4gbmV3ZXIgUG9kbWFuLgogICAgZXhwb3J0IFBPRE1BTl9DT01QT1NFX1dBUk5J
  >> "!B64TMP!" echo TkdfTE9HUz1mYWxzZQogIGVsc2UKICAgIGlmIGRvY2tlciBjb21wb3NlIHZlcnNpb24gPi9kZXYv
  >> "!B64TMP!" echo bnVsbCAyPiYxOyB0aGVuIERDPSJkb2NrZXIgY29tcG9zZSIKICAgIGVsaWYgY29tbWFuZCAtdiBk
  >> "!B64TMP!" echo b2NrZXItY29tcG9zZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4gREM9ImRvY2tlci1jb21wb3NlIgog
  >> "!B64TMP!" echo ICAgZWxzZQogICAgICBsc19lcnIgIkRvY2tlciBDb21wb3NlIHdhcyBub3QgZm91bmQuIEluc3Rh
  >> "!B64TMP!" echo bGwgdGhlICdkb2NrZXIgY29tcG9zZScgcGx1Z2luICh2MikuIgogICAgICByZXR1cm4gMQogICAg
  >> "!B64TMP!" echo ZmkKICBmaQogIHJldHVybiAwCn0KCiMgJ3BvZG1hbiBjb21wb3NlJyBub3JtYWxseSBoYW5kcyBv
  >> "!B64TMP!" echo dmVyIHRvIGRvY2tlci1jb21wb3NlLCB3aGljaCB0YWxrcyB0bwojIFBvZG1hbidzIEFQSSBzb2Nr
  >> "!B64TMP!" echo ZXQuIE9uIGEgZnJlc2ggRmVkb3JhIHNlc3Npb24gdGhhdCBzb2NrZXQgaXMgbm90IHJ1bm5pbmcs
  >> "!B64TMP!" echo IGFuZAojIGRvY2tlci1jb21wb3NlIHRoZW4gZmFpbHMgd2l0aCAiQ2Fubm90IGNvbm5lY3QgdG8g
  >> "!B64TMP!" echo dGhlIERvY2tlciBkYWVtb24iLiBTdGFydCBpdAojIHdoZW4gcG9zc2libGUuIFJldHVybnMgMCB3
  >> "!B64TMP!" echo aGVuIHRoZSBzb2NrZXQgZXhpc3RzIGFmdGVyd2FyZHMuIE5ldmVyIGZhdGFsOiBhCiMgY29tcG9z
  >> "!B64TMP!" echo ZSBwcm92aWRlciB0aGF0IGRvZXMgbm90IG5lZWQgdGhlIHNvY2tldCAocG9kbWFuLWNvbXBvc2Up
  >> "!B64TMP!" echo IHdvcmtzIGFueXdheS4KbHNfZW5zdXJlX3BvZG1hbl9zb2NrZXQoKSB7CiAgWyAiJEVOR0lORSIg
  >> "!B64TMP!" echo PSAicG9kbWFuIiBdICYmIFsgIiREQyIgPSAicG9kbWFuIGNvbXBvc2UiIF0gfHwgcmV0dXJuIDAK
  >> "!B64TMP!" echo ICBbICIkKHVuYW1lKSIgPSAiTGludXgiIF0gfHwgcmV0dXJuIDAKICBbICIkKHBvZG1hbiBpbmZv
  >> "!B64TMP!" echo IC0tZm9ybWF0ICd7ey5Ib3N0LlJlbW90ZVNvY2tldC5FeGlzdHN9fScgMj4vZGV2L251bGwpIiA9
  >> "!B64TMP!" echo ICJ0cnVlIiBdICYmIHJldHVybiAwCiAgaWYgY29tbWFuZCAtdiBzeXN0ZW1jdGwgPi9kZXYvbnVs
  >> "!B64TMP!" echo bCAyPiYxOyB0aGVuCiAgICBpZiBbICIkKHBvZG1hbiBpbmZvIC0tZm9ybWF0ICd7ey5Ib3N0LlNl
  >> "!B64TMP!" echo Y3VyaXR5LlJvb3RsZXNzfX0nIDI+L2Rldi9udWxsKSIgPSAidHJ1ZSIgXTsgdGhlbgogICAgICBz
  >> "!B64TMP!" echo eXN0ZW1jdGwgLS11c2VyIHN0YXJ0IHBvZG1hbi5zb2NrZXQgPi9kZXYvbnVsbCAyPiYxCiAgICBl
  >> "!B64TMP!" echo bHNlCiAgICAgIHN5c3RlbWN0bCBzdGFydCBwb2RtYW4uc29ja2V0ID4vZGV2L251bGwgMj4mMSBc
  >> "!B64TMP!" echo CiAgICAgICAgfHwgeyBjb21tYW5kIC12IHN1ZG8gPi9kZXYvbnVsbCAyPiYxICYmIHN1ZG8gLW4g
  >> "!B64TMP!" echo c3lzdGVtY3RsIHN0YXJ0IHBvZG1hbi5zb2NrZXQgPi9kZXYvbnVsbCAyPiYxOyB9CiAgICBmaQog
  >> "!B64TMP!" echo IGZpCiAgWyAiJChwb2RtYW4gaW5mbyAtLWZvcm1hdCAne3suSG9zdC5SZW1vdGVTb2NrZXQuRXhp
  >> "!B64TMP!" echo c3RzfX0nIDI+L2Rldi9udWxsKSIgPSAidHJ1ZSIgXQp9Cgpsc19zZWxpbnV4X29uKCkgewogIFsg
  >> "!B64TMP!" echo IiQodW5hbWUpIiA9ICJMaW51eCIgXSB8fCByZXR1cm4gMQogIGlmIGNvbW1hbmQgLXYgZ2V0ZW5m
  >> "!B64TMP!" echo b3JjZSA+L2Rldi9udWxsIDI+JjE7IHRoZW4KICAgIGNhc2UgIiQoZ2V0ZW5mb3JjZSAyPi9kZXYv
  >> "!B64TMP!" echo bnVsbCkiIGluIEVuZm9yY2luZ3xQZXJtaXNzaXZlKSByZXR1cm4gMCA7OyBlc2FjCiAgICByZXR1
  >> "!B64TMP!" echo cm4gMQogIGZpCiAgWyAtZSAvc3lzL2ZzL3NlbGludXgvZW5mb3JjZSBdCn0KCmxzX3BvZG1hbl9y
  >> "!B64TMP!" echo b290bGVzcygpIHsKICBbICIkKHBvZG1hbiBpbmZvIC0tZm9ybWF0ICd7ey5Ib3N0LlNlY3VyaXR5
  >> "!B64TMP!" echo LlJvb3RsZXNzfX0nIDI+L2Rldi9udWxsKSIgPSAidHJ1ZSIgXQp9CgojIERlY2lkZXMgdGhlIHR3
  >> "!B64TMP!" echo byBTZWFyWE5HIGJpbmQtbW91bnQgc2V0dGluZ3MgdGhhdCB0aGUgaW5zdGFsbGVyIHdyaXRlcyB0
  >> "!B64TMP!" echo byAuZW52CiMgKHRoZXkgZmVlZCAke1NFQVJYTkdfTU9VTlRfT1BUU30gLyAke1NFQVJYTkdfRk9S
  >> "!B64TMP!" echo Q0VfT1dORVJTSElQfSBpbiB0aGUgY29tcG9zZSBmaWxlKToKIyAgIExTX01PVU5UX09QVFMgICAg
  >> "!B64TMP!" echo ICAgIix6IiBvbiBTRUxpbnV4IGhvc3RzIChsZXRzIHRoZSBjb250YWluZXIgcmVhZCB0aGUgZm9s
  >> "!B64TMP!" echo ZGVyKQojICAgTFNfRk9SQ0VfT1dORVJTSElQICAiZmFsc2UiIG9uIHJvb3RsZXNzIFBvZG1hbiAo
  >> "!B64TMP!" echo a2VlcHMgdGhlIGZpbGVzIHlvdXJzKSwgZWxzZSAidHJ1ZSIKbHNfcGxhdGZvcm1fZW52KCkgewog
  >> "!B64TMP!" echo IExTX01PVU5UX09QVFM9IiI7IExTX0ZPUkNFX09XTkVSU0hJUD0idHJ1ZSIKICBpZiBsc19zZWxp
  >> "!B64TMP!" echo bnV4X29uOyB0aGVuIExTX01PVU5UX09QVFM9Iix6IjsgZmkKICBpZiBbICIkRU5HSU5FIiA9ICJw
  >> "!B64TMP!" echo b2RtYW4iIF0gJiYgbHNfcG9kbWFuX3Jvb3RsZXNzOyB0aGVuIExTX0ZPUkNFX09XTkVSU0hJUD0i
  >> "!B64TMP!" echo ZmFsc2UiOyBmaQogIHJldHVybiAwCn0KCiMgbHNfaHR0cF9vayBQT1JUIC0+IDAgd2hlbiBzb21l
  >> "!B64TMP!" echo dGhpbmcgYW5zd2VycyBIVFRQIG9uIGxvY2FsaG9zdDpQT1JULiBBIGJhcmUgVENQCiMgY29ubmVj
  >> "!B64TMP!" echo dCBpcyBub3QgZW5vdWdoOiB0aGUgZW5naW5lIHB1Ymxpc2hlcyB0aGUgcG9ydCBldmVuIHdoaWxl
  >> "!B64TMP!" echo IHRoZSBjb250YWluZXIKIyBiZWhpbmQgaXQgaXMgY3Jhc2gtbG9vcGluZy4KbHNfaHR0cF9vaygp
  >> "!B64TMP!" echo IHsKICAoCiAgICBleGVjIDM8PiIvZGV2L3RjcC8xMjcuMC4wLjEvJDEiIHx8IGV4aXQgMQogICAg
  >> "!B64TMP!" echo cHJpbnRmICdHRVQgLyBIVFRQLzEuMFxyXG5Ib3N0OiBsb2NhbGhvc3RcclxuXHJcbicgPiYzCiAg
  >> "!B64TMP!" echo ICBsaW5lPSIiCiAgICBJRlM9IHJlYWQgLXIgLXQgMyBsaW5lIDwmMyB8fCBleGl0IDEKICAgIGNh
  >> "!B64TMP!" echo c2UgIiRsaW5lIiBpbiBIVFRQLyopIGV4aXQgMCA7OyBlc2FjCiAgICBleGl0IDEKICApIDI+L2Rl
  >> "!B64TMP!" echo di9udWxsCn0KCiMgbHNfdmVyaWZ5X3NlYXJ4bmcgUE9SVCAgKHJ1biBmcm9tIHRoZSBpbnN0YWxs
  >> "!B64TMP!" echo IGZvbGRlcjsgbmVlZHMgJERDKQojIFdhaXRzIHVwIHRvIExPQ0FMX1NFQVJDSF9WRVJJRllfVElN
  >> "!B64TMP!" echo RU9VVCBzZWNvbmRzIChkZWZhdWx0IDkwLCAwID0gc2tpcCkuIFdoZW4KIyBTZWFyWE5HIG5ldmVy
  >> "!B64TMP!" echo IGFuc3dlcnMgaXQgcHJpbnRzIHRoZSBjb250YWluZXIgc3RhdGUgKyBsYXN0IGxvZyBsaW5lcyBh
  >> "!B64TMP!" echo bmQsIGZvcgojIHBlcm1pc3Npb24gZXJyb3JzLCB0aGUgU0VMaW51eCBmaXguIFJldHVybnMgMSBp
  >> "!B64TMP!" echo biB0aGF0IGNhc2UuCmxzX3ZlcmlmeV9zZWFyeG5nKCkgewogIGxvY2FsIHBvcnQ9IiQxIiBsaW1p
  >> "!B64TMP!" echo dD0iJHtMT0NBTF9TRUFSQ0hfVkVSSUZZX1RJTUVPVVQ6LTkwfSIgd2FpdGVkPTAgbG9ncz0iIgog
  >> "!B64TMP!" echo IFsgIiRsaW1pdCIgLWd0IDAgXSAyPi9kZXYvbnVsbCB8fCByZXR1cm4gMAogIGxzX3NheSAiQ2hl
  >> "!B64TMP!" echo Y2tpbmcgdGhhdCBTZWFyWE5HIGFuc3dlcnMgb24gcG9ydCAkcG9ydCAodXAgdG8gJHtsaW1pdH1z
  >> "!B64TMP!" echo KS4uLiIKICB3aGlsZSA6OyBkbwogICAgaWYgbHNfaHR0cF9vayAiJHBvcnQiOyB0aGVuIGxzX29r
  >> "!B64TMP!" echo ICJTZWFyWE5HIGlzIGFuc3dlcmluZyBvbiBwb3J0ICRwb3J0LiI7IHJldHVybiAwOyBmaQogICAg
  >> "!B64TMP!" echo WyAiJHdhaXRlZCIgLWdlICIkbGltaXQiIF0gJiYgYnJlYWsKICAgIHNsZWVwIDMKICAgIHdhaXRl
  >> "!B64TMP!" echo ZD0kKCh3YWl0ZWQgKyAzKSkKICBkb25lCiAgbHNfZXJyICJTZWFyWE5HIGRpZCBub3QgYW5zd2Vy
  >> "!B64TMP!" echo IG9uIHBvcnQgJHBvcnQgd2l0aGluICR7bGltaXR9cy4iCiAgbHNfc2F5ICIiCiAgbHNfc2F5ICIg
  >> "!B64TMP!" echo IENvbnRhaW5lciBzdGF0ZToiCiAgJERDIHBzIDI+JjEgfCBzZWQgJ3MvXi8gICAgLycgfCBoZWFk
  >> "!B64TMP!" echo IC1uIDEyCiAgbG9ncz0iJCgkREMgbG9ncyAtLXRhaWwgMTUgc2VhcnhuZyAyPiYxKSIKICBsc19z
  >> "!B64TMP!" echo YXkgIiAgTGFzdCBTZWFyWE5HIGxvZyBsaW5lczoiCiAgcHJpbnRmICclc1xuJyAiJGxvZ3MiIHwg
  >> "!B64TMP!" echo c2VkICdzL14vICAgIC8nCiAgaWYgcHJpbnRmICclcycgIiRsb2dzIiB8IGdyZXAgLXFpICJwZXJt
  >> "!B64TMP!" echo aXNzaW9uIGRlbmllZCI7IHRoZW4KICAgIGxzX3NheSAiIgogICAgbHNfc2F5ICIgIFRoaXMgaXMg
  >> "!B64TMP!" echo YSBiaW5kLW1vdW50IHBlcm1pc3Npb24gcHJvYmxlbSAodHlwaWNhbCBvbiBGZWRvcmEgLyBSSEVM
  >> "!B64TMP!" echo IHdpdGgiCiAgICBsc19zYXkgIiAgU0VMaW51eCkuIFRoZSBjb21wb3NlIGZpbGUgbGFiZWxzIHRo
  >> "!B64TMP!" echo ZSBTZWFyWE5HIGNvbmZpZyBmb2xkZXIgdGhyb3VnaCIKICAgIGxzX3NheSAiICBTRUFSWE5HX01P
  >> "!B64TMP!" echo VU5UX09QVFMgaW4gLmVudiwgd2hpY2ggc2hvdWxkIHJlYWQ6ICBTRUFSWE5HX01PVU5UX09QVFM9
  >> "!B64TMP!" echo LHoiCiAgICBsc19zYXkgIiAgQ2hlY2s6ICBncmVwIFNFQVJYTkcgLmVudiA7IGdldGVuZm9yY2Ui
  >> "!B64TMP!" echo CiAgICBsc19zYXkgIiAgVGhlbiByZXN0YXJ0IHdpdGggLi9ydW4uc2ggKG9yIHJlLXJ1biB0aGUg
  >> "!B64TMP!" echo aW5zdGFsbGVyKS4iCiAgZmkKICByZXR1cm4gMQp9CgojIC0tLS0ga2VlcCB0aGUgd2luZG93IG9w
  >> "!B64TMP!" echo ZW4gLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0KIyBBIHRlcm1pbmFsIG9wZW5lZCBieSBhIGZpbGUgbWFuYWdlciAvIGxhdW5jaGVyIGNsb3Nl
  >> "!B64TMP!" echo cyB0aGUgbW9tZW50IHRoZSBzY3JpcHQgZW5kcywKIyB0YWtpbmcgYWxsIG91dHB1dCB3aXRoIGl0
  >> "!B64TMP!" echo LiBXaGVuIG5vIGludGVyYWN0aXZlIHNoZWxsIHN0YXJ0ZWQgdXMsIHdhaXQgZm9yIGEga2V5IHBy
  >> "!B64TMP!" echo ZXNzCiMgYmVmb3JlIGV4aXRpbmcgKFJ1bi5iYXQgLyBJbnN0YWxsLmJhdCBkbyB0aGUgc2FtZSB3
  >> "!B64TMP!" echo aXRoIGBwYXVzZWApLgojICAgTE9DQUxfU0VBUkNIX1BBVVNFPTAgICAgbmV2ZXIgd2FpdCAgICAg
  >> "!B64TMP!" echo IExPQ0FMX1NFQVJDSF9QQVVTRT0xICAgYWx3YXlzIHdhaXQgKG9uIGEgdGVybWluYWwpCmxzX2xh
  >> "!B64TMP!" echo dW5jaGVkX2Zyb21fc2hlbGwoKSB7ICAgIyAwID0gYW4gaW50ZXJhY3RpdmUgc2hlbGwgc3RhcnRl
  >> "!B64TMP!" echo ZCB1cyAodGhlIHRlcm1pbmFsIHN0YXlzIG9wZW4pCiAgbG9jYWwgcGlkPSIke1BQSUQ6LTB9IiBj
  >> "!B64TMP!" echo b21tPSIiIGFyZ3M9IiIgaG9wcz0wCiAgY29tbWFuZCAtdiBwcyA+L2Rldi9udWxsIDI+JjEgfHwg
  >> "!B64TMP!" echo cmV0dXJuIDEKICB3aGlsZSBbICIkcGlkIiAtZ3QgMSBdIDI+L2Rldi9udWxsICYmIFsgIiRob3Bz
  >> "!B64TMP!" echo IiAtbHQgOCBdOyBkbwogICAgY29tbT0iJChwcyAtbyBjb21tPSAtcCAiJHBpZCIgMj4vZGV2L251
  >> "!B64TMP!" echo bGwgfCB0ciAtZCAnICcpIjsgY29tbT0iJHtjb21tIyMqL30iOyBjb21tPSIke2NvbW0jLX0iCiAg
  >> "!B64TMP!" echo ICBhcmdzPSIkKHBzIC1vIGFyZ3M9IC1wICIkcGlkIiAyPi9kZXYvbnVsbCkiCiAgICBjYXNlICIk
  >> "!B64TMP!" echo Y29tbSIgaW4KICAgICAgYmFzaHx6c2h8c2h8ZGFzaHxmaXNofGtzaHxta3NofGFzaHx0Y3NofGNz
  >> "!B64TMP!" echo aHxudXxlbHZpc2h8eG9uc2gpCiAgICAgICAgIyBgc2ggLWMgIi4vc2NyaXB0ImAgaXMganVzdCBh
  >> "!B64TMP!" echo IGxhdW5jaGVyJ3Mgd3JhcHBlciAtIGxvb2sgdGhyb3VnaCBpdAogICAgICAgIGNhc2UgIiAkYXJn
  >> "!B64TMP!" echo cyAiIGluICoiIC1jICIqKSA7OyAqKSByZXR1cm4gMCA7OyBlc2FjIDs7CiAgICAgIHN1ZG98ZG9h
  >> "!B64TMP!" echo c3xlbnZ8dGltZXx0aW1lb3V0fG5pY2V8c2V0c2lkfHN0ZGJ1ZnxzY3JpcHR8cGtleGVjfHN1fG5v
  >> "!B64TMP!" echo aHVwKSA7OwogICAgICAqKSByZXR1cm4gMSA7OwogICAgZXNhYwogICAgcGlkPSIkKHBzIC1vIHBw
  >> "!B64TMP!" echo aWQ9IC1wICIkcGlkIiAyPi9kZXYvbnVsbCB8IHRyIC1kICcgJykiOyBob3BzPSQoKGhvcHMgKyAx
  >> "!B64TMP!" echo KSkKICBkb25lCiAgcmV0dXJuIDEKfQoKbHNfcGF1c2Vfbm93KCkgewogIHByaW50ZiAnXG4nCiAg
  >> "!B64TMP!" echo cHJpbnRmICdQcmVzcyBhbnkga2V5IHRvIGNsb3NlIHRoaXMgd2luZG93Li4uICcKICByZWFkIC1u
  >> "!B64TMP!" echo IDEgLXMgX2xzX3ggPC9kZXYvdHR5IDI+L2Rldi9udWxsIHx8IHJlYWQgLW4gMSAtcyBfbHNfeCAy
  >> "!B64TMP!" echo Pi9kZXYvbnVsbCB8fCBzbGVlcCAzMAp9Cgpsc19wYXVzZV9vbl9leGl0KCkgewogIGNhc2UgIiQo
  >> "!B64TMP!" echo bHNfbG93ZXIgIiR7TE9DQUxfU0VBUkNIX1BBVVNFOi1hdXRvfSIpIiBpbgogICAgMHxub3xmYWxz
  >> "!B64TMP!" echo ZXxuZXZlcikgcmV0dXJuIDAgOzsKICAgIDF8eWVzfHRydWV8YWx3YXlzKSA7OwogICAgKikgbHNf
  >> "!B64TMP!" echo bGF1bmNoZWRfZnJvbV9zaGVsbCAmJiByZXR1cm4gMCA7OwogIGVzYWMKICB7IFsgLXQgMCBdICYm
  >> "!B64TMP!" echo IFsgLXQgMSBdOyB9IHx8IHJldHVybiAwCiAgIyBzaGVsbGNoZWNrIGRpc2FibGU9U0MyMTU0CiAg
  >> "!B64TMP!" echo dHJhcCAnX2xzX3JjPSQ/OyBsc19wYXVzZV9ub3c7IGV4aXQgJF9sc19yYycgRVhJVAp9CgojIC0t
  >> "!B64TMP!" echo LS0gaW5oZXJpdGVkIHByb3h5IHZhcmlhYmxlcyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiMgUG9kbWFuIGNvcGllcyB0aGUgaG9zdCBzaGVsbCdz
  >> "!B64TMP!" echo IGh0dHBfcHJveHkgLyBodHRwc19wcm94eSAvIC4uLiBpbnRvIGV2ZXJ5IGNvbnRhaW5lcgojIChE
  >> "!B64TMP!" echo b2NrZXIgZG9lcyBub3QpLiBBIGxvb3BiYWNrIHZhbHVlIHN1Y2ggYXMgaHR0cDovLzEyNy4wLjAu
  >> "!B64TMP!" echo MTo3ODkwIHBvaW50cyBhdCB0aGUKIyBjb250YWluZXIgaXRzZWxmIHRoZXJlLCBzbyBldmVyeSBv
  >> "!B64TMP!" echo dXRnb2luZyByZXF1ZXN0IGZhaWxzIGF0IG9uY2UgKCJGYWlsZWQgdG8gY29ubmVjdCBvdmVyCiMg
  >> "!B64TMP!" echo cHJveHkgMTI3LjAuMC4xIGFmdGVyIDAgbXMiKSBhbHRob3VnaCBldmVyeSBjb250YWluZXIgc2hv
  >> "!B64TMP!" echo d3MgIlVwIi4gV2hhdCB0aGUgY29udGFpbmVycwojIGFjdHVhbGx5IHJlY2VpdmVkIGlzIGluc3Bl
  >> "!B64TMP!" echo Y3RlZCwgYW5kIGV4YWN0bHkgdGhvc2UgbG9vcGJhY2sgdmFyaWFibGVzIGFyZSBibGFua2VkIHRo
  >> "!B64TMP!" echo cm91Z2ggYQojIGdlbmVyYXRlZCBkb2NrZXItY29tcG9zZS5vdmVycmlkZS55bWwgKGRvY2tlciBj
  >> "!B64TMP!" echo b21wb3NlIGFuZCBwb2RtYW4tY29tcG9zZSBsb2FkIGl0CiMgYXV0b21hdGljYWxseSkuIFByb3hp
  >> "!B64TMP!" echo ZXMgdGhhdCBwb2ludCBhdCBhIHJlYWwgaG9zdCAoY29ycG9yYXRlLCBMQU4pIGFyZSBsZWZ0IGFs
  >> "!B64TMP!" echo b25lLgpMU19PVkVSUklERT0iZG9ja2VyLWNvbXBvc2Uub3ZlcnJpZGUueW1sIgpMU19PVkVSUklE
  >> "!B64TMP!" echo RV9NQVJLPSIjIGxvY2FsLXNlYXJjaDogZ2VuZXJhdGVkIGNvbnRhaW5lci1uZXR3b3JrIHdvcmth
  >> "!B64TMP!" echo cm91bmQiCkxTX09WUl9QUk9YWT0iIiAgICAgICMgc3BhY2Ugc2VwYXJhdGVkIChsb3dlcmNhc2Up
  >> "!B64TMP!" echo IHByb3h5IHZhcmlhYmxlIG5hbWVzIGJsYW5rZWQgYnkgdGhlIG92ZXJyaWRlCgpsc19vdmVycmlk
  >> "!B64TMP!" echo ZV9pc19vdXJzKCkgeyBbIC1mICIkTFNfT1ZFUlJJREUiIF0gJiYgaGVhZCAtbiAxICIkTFNfT1ZF
  >> "!B64TMP!" echo UlJJREUiIDI+L2Rldi9udWxsIHwgZ3JlcCAtcSAiXiMgbG9jYWwtc2VhcmNoOiBnZW5lcmF0ZWQg
  >> "!B64TMP!" echo Y29udGFpbmVyLSI7IH0KCiMgUmVzdG9yZSB0aGUgdmFyaWFibGUgbGlzdCBmcm9tIGFuIG92ZXJy
  >> "!B64TMP!" echo aWRlIHRoaXMgdG9vbCB3cm90ZSBlYXJsaWVyLgpsc19vdmVycmlkZV9sb2FkKCkgewogIExTX09W
  >> "!B64TMP!" echo Ul9QUk9YWT0iIgogIGxzX292ZXJyaWRlX2lzX291cnMgfHwgcmV0dXJuIDAKICBMU19PVlJfUFJP
  >> "!B64TMP!" echo WFk9IiQoc2VkIC1uICdzL14jIGxzLXByb3h5LXZhcnM6ICovL3AnICIkTFNfT1ZFUlJJREUiIHwg
  >> "!B64TMP!" echo aGVhZCAtbiAxIHwgdHIgJ0EtWiAnICdhLXpcbicgfCBncmVwIC12ICdeJCcgfCBzb3J0IC11IHwg
  >> "!B64TMP!" echo dHIgJ1xuJyAnICcgfCBzZWQgJ3MvICokLy8nKSIKfQoKIyBXcml0ZXMgdGhlIG92ZXJyaWRlIGZy
  >> "!B64TMP!" echo b20gTFNfT1ZSX1BST1hZOyByZW1vdmVzIGl0IHdoZW4gdGhlIGxpc3QgaXMgZW1wdHkuCmxzX292
  >> "!B64TMP!" echo ZXJyaWRlX3dyaXRlKCkgewogIGxvY2FsIHN2YyB2IHVjCiAgaWYgWyAteiAiJExTX09WUl9QUk9Y
  >> "!B64TMP!" echo WSIgXTsgdGhlbiBybSAtZiAiJExTX09WRVJSSURFIjsgcmV0dXJuIDA7IGZpCiAgewogICAgZWNo
  >> "!B64TMP!" echo byAiJExTX09WRVJSSURFX01BUksgKHNhZmUgdG8gZGVsZXRlIC0gdGhlIGluc3RhbGxlciByZXdy
  >> "!B64TMP!" echo aXRlcyBpdCkiCiAgICBlY2hvICIjIGxzLXByb3h5LXZhcnM6ICRMU19PVlJfUFJPWFkiCiAgICBl
  >> "!B64TMP!" echo Y2hvICIjIFByb3h5IHZhcmlhYmxlcyBjb3BpZWQgZnJvbSB0aGUgaG9zdCBzaGVsbCBwb2ludCBh
  >> "!B64TMP!" echo dCAxMjcuMC4wLjEsIHdoaWNoIGluc2lkZSBhIGNvbnRhaW5lciBpcyIKICAgIGVjaG8gIiMgdGhl
  >> "!B64TMP!" echo IGNvbnRhaW5lciBpdHNlbGY6IGJsYW5rZWQgZm9yIGV2ZXJ5IHNlcnZpY2UgdGhhdCBuZWVkcyB0
  >> "!B64TMP!" echo aGUgaW50ZXJuZXQuIgogICAgZWNobyAic2VydmljZXM6IgogICAgZm9yIHN2YyBpbiBzZWFyeG5n
  >> "!B64TMP!" echo IGZpcmVjcmF3bCBwbGF5d3JpZ2h0LXNlcnZpY2UgYnJvd3Nlcmxlc3M7IGRvCiAgICAgIGVjaG8g
  >> "!B64TMP!" echo IiAgJHN2YzoiCiAgICAgIGVjaG8gIiAgICBlbnZpcm9ubWVudDoiCiAgICAgIGZvciB2IGluICRM
  >> "!B64TMP!" echo U19PVlJfUFJPWFk7IGRvCiAgICAgICAgdWM9IiQocHJpbnRmICclcycgIiR2IiB8IHRyICdbOmxv
  >> "!B64TMP!" echo d2VyOl0nICdbOnVwcGVyOl0nKSIKICAgICAgICBlY2hvICIgICAgICAtIFwiJHY9XCIiCiAgICAg
  >> "!B64TMP!" echo ICAgZWNobyAiICAgICAgLSBcIiR1Yz1cIiIKICAgICAgZG9uZQogICAgZG9uZQogIH0gPiAiJExT
  >> "!B64TMP!" echo X09WRVJSSURFIgp9CgojIFByaW50cyAiTkFNRT12YWx1ZSIgZm9yIGV2ZXJ5IHByb3h5IHZhcmlh
  >> "!B64TMP!" echo YmxlIGluc2lkZSB0aGUgU2VhclhORyBjb250YWluZXIgdGhhdCBwb2ludHMgYXQKIyB0aGlzIHZl
  >> "!B64TMP!" echo cnkgY29udGFpbmVyIChsb2NhbGhvc3QgLyAxMjcueCAvIDo6MSksIG9uZSBwZXIgbGluZS4gTm90
  >> "!B64TMP!" echo aGluZyB3aGVuIGFsbCBpcyB3ZWxsLgpsc19jb250YWluZXJfbG9vcGJhY2tfcHJveGllcygpIHsK
  >> "!B64TMP!" echo ICBsb2NhbCBlbnZ0eHQgbGluZSBuYW1lIHZhbCBob3N0CiAgZW52dHh0PSIkKCIkRU5HSU5FIiBl
  >> "!B64TMP!" echo eGVjIGxvY2FsLXNlYXJjaC1zZWFyeG5nIGVudiAyPi9kZXYvbnVsbCkiIHx8IHJldHVybiAwCiAg
  >> "!B64TMP!" echo d2hpbGUgSUZTPSByZWFkIC1yIGxpbmU7IGRvCiAgICBuYW1lPSIke2xpbmUlJT0qfSI7IHZhbD0i
  >> "!B64TMP!" echo JHtsaW5lIyo9fSIKICAgIGNhc2UgIiQobHNfbG93ZXIgIiRuYW1lIikiIGluIGh0dHBfcHJveHl8
  >> "!B64TMP!" echo aHR0cHNfcHJveHl8YWxsX3Byb3h5fGZ0cF9wcm94eSkgOzsgKikgY29udGludWUgOzsgZXNhYwog
  >> "!B64TMP!" echo ICAgWyAtbiAiJHZhbCIgXSB8fCBjb250aW51ZQogICAgaG9zdD0iJHt2YWwjKjovL30iOyBob3N0
  >> "!B64TMP!" echo PSIke2hvc3QjIypAfSIKICAgIGNhc2UgIiRob3N0IiBpbgogICAgICBcWyopIGhvc3Q9IiR7aG9z
  >> "!B64TMP!" echo dCNcW30iOyBob3N0PSIke2hvc3QlJVxdKn0iIDs7CiAgICAgICopICAgaG9zdD0iJHtob3N0JSVb
  >> "!B64TMP!" echo Oi9dKn0iIDs7CiAgICBlc2FjCiAgICBjYXNlICIkaG9zdCIgaW4gbG9jYWxob3N0fDEyNy4qfDo6
  >> "!B64TMP!" echo MXwwLjAuMC4wKSBwcmludGYgJyVzPSVzXG4nICIkbmFtZSIgIiR2YWwiIDs7IGVzYWMKICBkb25l
  >> "!B64TMP!" echo IDw8RU9GCiRlbnZ0eHQKRU9GCn0KCmxzX3dhaXRfaHR0cCgpIHsgICAjIGxzX3dhaXRfaHR0cCBQ
  >> "!B64TMP!" echo T1JUIFNFQ09ORFMKICBsb2NhbCB3YWl0ZWQ9MAogIHdoaWxlICEgbHNfaHR0cF9vayAiJDEiOyBk
  >> "!B64TMP!" echo bwogICAgWyAiJHdhaXRlZCIgLWdlICIkMiIgXSAmJiByZXR1cm4gMQogICAgc2xlZXAgMjsgd2Fp
  >> "!B64TMP!" echo dGVkPSQoKHdhaXRlZCArIDIpKQogIGRvbmUKfQoKIyBsc19maXhfY29udGFpbmVyX3Byb3h5IFBP
  >> "!B64TMP!" echo UlQgIChydW4gZnJvbSB0aGUgaW5zdGFsbCBmb2xkZXI7IG5lZWRzICREQyBhbmQgdGhlIHN0YWNr
  >> "!B64TMP!" echo IHVwKQpsc19maXhfY29udGFpbmVyX3Byb3h5KCkgewogIGxvY2FsIHBvcnQ9IiQxIiBiYWQgbmFt
  >> "!B64TMP!" echo ZXMgdiBvdXQKICBbICIke0xPQ0FMX1NFQVJDSF9WRVJJRllfVElNRU9VVDotOTB9IiAtZ3QgMCBd
  >> "!B64TMP!" echo IDI+L2Rldi9udWxsIHx8IHJldHVybiAwCiAgbHNfc2F5ICJDaGVja2luZyB0aGUgY29udGFpbmVy
  >> "!B64TMP!" echo cycgcHJveHkgc2V0dGluZ3MuLi4iCiAgYmFkPSIkKGxzX2NvbnRhaW5lcl9sb29wYmFja19wcm94
  >> "!B64TMP!" echo aWVzKSIKICBpZiBbIC16ICIkYmFkIiBdOyB0aGVuIGxzX29rICJUaGUgY29udGFpbmVycycgcHJv
  >> "!B64TMP!" echo eHkgc2V0dGluZ3MgYXJlIGZpbmUuIjsgcmV0dXJuIDA7IGZpCgogIGxzX2VyciAiVGhlIGNvbnRh
  >> "!B64TMP!" echo aW5lcnMgaW5oZXJpdGVkIGEgcHJveHkgc2V0dGluZyB0aGF0IGNhbm5vdCB3b3JrIGZyb20gaW5z
  >> "!B64TMP!" echo aWRlIGEgY29udGFpbmVyOiIKICBwcmludGYgJyVzXG4nICIkYmFkIiB8IHNlZCAncy9eLyAgICAg
  >> "!B64TMP!" echo IC8nCiAgbHNfc2F5ICIgIChQb2RtYW4gY29waWVzIHlvdXIgc2hlbGwncyBwcm94eSB2YXJpYWJs
  >> "!B64TMP!" echo ZXMgaW50byBldmVyeSBjb250YWluZXI7IDEyNy4wLjAuMSB0aGVyZSBpcyIKICBsc19zYXkgIiAg
  >> "!B64TMP!" echo IHRoZSBjb250YWluZXIgaXRzZWxmLCBzbyBldmVyeSBvdXRnb2luZyByZXF1ZXN0IGZhaWxzIGF0
  >> "!B64TMP!" echo IG9uY2UgLSBzZWFyY2hlcyBzdGF5IGVtcHR5LikiCiAgaWYgWyAtZiAiJExTX09WRVJSSURFIiBd
  >> "!B64TMP!" echo ICYmICEgbHNfb3ZlcnJpZGVfaXNfb3VyczsgdGhlbgogICAgbHNfc2F5ICIgICRMU19PVkVSUklE
  >> "!B64TMP!" echo RSBleGlzdHMgYW5kIGlzIG5vdCBvdXJzLCBzbyBJIHdpbGwgbm90IGNoYW5nZSBpdC4gQWRkIHRv
  >> "!B64TMP!" echo IHRoZSAnZW52aXJvbm1lbnQ6JyBvZiIKICAgIGxzX3NheSAiICBzZWFyeG5nLCBmaXJlY3Jhd2ws
  >> "!B64TMP!" echo IHBsYXl3cmlnaHQtc2VydmljZSBhbmQgYnJvd3Nlcmxlc3MsIHNldCB0byBlbXB0eToiCiAgICBs
  >> "!B64TMP!" echo c19zYXkgIiAgICBodHRwX3Byb3h5PSAgIGh0dHBzX3Byb3h5PSAgIGFsbF9wcm94eT0gICAoYW5k
  >> "!B64TMP!" echo IHRoZSBVUFBFUkNBU0UgdHdpbnMpIgogICAgcmV0dXJuIDEKICBmaQogIGxzX292ZXJyaWRlX2xv
  >> "!B64TMP!" echo YWQKICBuYW1lcz0iIgogIHdoaWxlIElGUz0gcmVhZCAtciB2OyBkbyBbIC1uICIkdiIgXSAmJiBu
  >> "!B64TMP!" echo YW1lcz0iJG5hbWVzICQobHNfbG93ZXIgIiR7diUlPSp9IikiOyBkb25lIDw8RU9GCiRiYWQKRU9G
  >> "!B64TMP!" echo CiAgIyBzaGVsbGNoZWNrIGRpc2FibGU9U0MyMDg2CiAgTFNfT1ZSX1BST1hZPSIkKHByaW50ZiAn
  >> "!B64TMP!" echo JXNcbicgJExTX09WUl9QUk9YWSAkbmFtZXMgfCBzb3J0IC11IHwgdHIgJ1xuJyAnICcgfCBzZWQg
  >> "!B64TMP!" echo J3MvICokLy8nKSIKICBsc19zYXkgIiAgLT4gcmVtb3ZpbmcgdGhvc2UgdmFyaWFibGVzIGluc2lk
  >> "!B64TMP!" echo ZSB0aGUgY29udGFpbmVycyAod3JpdHRlbiB0byAkTFNfT1ZFUlJJREUpLi4uIgogIGxzX292ZXJy
  >> "!B64TMP!" echo aWRlX3dyaXRlCiAgaWYgISBvdXQ9IiQoJERDIHVwIC1kIDI+JjEpIjsgdGhlbgogICAgbHNfc2F5
  >> "!B64TMP!" echo ICIgIFshXSAnJERDIHVwIC1kJyBmYWlsZWQgd2hpbGUgYXBwbHlpbmcgaXQ6IgogICAgcHJpbnRm
  >> "!B64TMP!" echo ICclc1xuJyAiJG91dCIgfCB0YWlsIC1uIDUgfCBzZWQgJ3MvXi8gICAgICAvJwogICAgcmV0dXJu
  >> "!B64TMP!" echo IDEKICBmaQogIGxzX3dhaXRfaHR0cCAiJHBvcnQiIDYwIHx8IHRydWUKICBpZiBbIC1uICIkKGxz
  >> "!B64TMP!" echo X2NvbnRhaW5lcl9sb29wYmFja19wcm94aWVzKSIgXTsgdGhlbgogICAgbHNfZXJyICJUaGUgY29u
  >> "!B64TMP!" echo dGFpbmVycyBzdGlsbCBjYXJyeSBhIGxvb3BiYWNrIHByb3h5LiBVbnNldCBpdCBpbiB5b3VyIHNo
  >> "!B64TMP!" echo ZWxsIGFuZCBydW4gLi9ydW4uc2g6IgogICAgbHNfc2F5ICIgICAgdW5zZXQgaHR0cF9wcm94eSBo
  >> "!B64TMP!" echo dHRwc19wcm94eSBhbGxfcHJveHkgSFRUUF9QUk9YWSBIVFRQU19QUk9YWSBBTExfUFJPWFkiCiAg
  >> "!B64TMP!" echo ICByZXR1cm4gMQogIGZpCiAgbHNfb2sgIlRoZSBpbmhlcml0ZWQgbG9vcGJhY2sgcHJveHkgaXMg
  >> "!B64TMP!" echo Z29uZSBmcm9tIHRoZSBjb250YWluZXJzIChzZWUgJExTX09WRVJSSURFOyBkZWxldGUgaXQgdG8g
  >> "!B64TMP!" echo dW5kbykuIgogIHJldHVybiAwCn0KCiMgRm9yIHJ1bi5zaCAvIHN0b3Auc2ggLyB1cGRhdGUuc2gg
  >> "!B64TMP!" echo LyB1bmluc3RhbGwuc2ggKGN3ZCA9IHRoZSBpbnN0YWxsIGZvbGRlcikuCmxzX3JlcXVpcmVfZW5n
  >> "!B64TMP!" echo aW5lKCkgewogIGxzX3NlbGVjdF9lbmdpbmUgIi4vLmVudiIgfHwgZXhpdCAxCiAgaWYgWyAiJHsx
  >> "!B64TMP!" echo Oi19IiA9ICJydW5uaW5nIiBdICYmICEgbHNfZW5naW5lX3J1bm5pbmc7IHRoZW4KICAgIGlmIGxz
  >> "!B64TMP!" echo X2ZhbGxiYWNrX2VuZ2luZTsgdGhlbgogICAgICBsc19zYXkgIiAgWyFdIFBvZG1hbiBpcyBub3Qg
  >> "!B64TMP!" echo cmVzcG9uZGluZyAtIHVzaW5nIERvY2tlciBpbnN0ZWFkLiIKICAgIGVsc2UKICAgICAgbHNfZXJy
  >> "!B64TMP!" echo ICJUaGUgJEVOR0lORV9OQU1FIGVuZ2luZSBpcyBub3QgcnVubmluZy4gU3RhcnQgaXQgZmlyc3Qu
  >> "!B64TMP!" echo IgogICAgICBsc19lbmdpbmVfaGludAogICAgICBleGl0IDEKICAgIGZpCiAgZmkKICBsc19zZWxl
  >> "!B64TMP!" echo Y3RfY29tcG9zZSB8fCBleGl0IDEKICBsc19lbnN1cmVfcG9kbWFuX3NvY2tldCB8fCBsc19zYXkg
  >> "!B64TMP!" echo IiAgWyFdIFBvZG1hbidzIEFQSSBzb2NrZXQgaXMgbm90IGFjdGl2ZSAtIGlmIGNvbXBvc2UgZmFp
  >> "!B64TMP!" echo bHMsIHJ1bjogc3lzdGVtY3RsIC0tdXNlciBlbmFibGUgLS1ub3cgcG9kbWFuLnNvY2tldCIKfQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\engine.sh"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/SKILL.md ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\SKILL.md" (
  copy /Y "!SRC!\local-web-search\SKILL.md" "!TARGET!\local-web-search\SKILL.md" >nul 2>&1
  if exist "!TARGET!\local-web-search\SKILL.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/SKILL.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1507658164.b64"
  > "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYi1zZWFyY2gKZGVzY3JpcHRpb246ID4tCiAgV2ViIHNlYXJjaCwg
  >> "!B64TMP!" echo cGFnZS1yZWFkaW5nLCBzY3JhcGluZyBhbmQgY3Jhd2xpbmcgdmlhIFNlYXJYTkcgKyBGaXJlY3Jh
  >> "!B64TMP!" echo d2wKICAoYXV0by1zdGFydHMgRG9ja2VyKS4KICBUb29sczogc2VhcmNoLCBzY3JhcGUsIG1hcCwg
  >> "!B64TMP!" echo Y3Jhd2wsIGNyYXdsIHN0YXR1cywgWW91VHViZSB0cmFuc2NyaXB0cywKICBwbHVzIDE5IG1vcmUg
  >> "!B64TMP!" echo d2l0aCBhIEZpcmVjcmF3bCBBUEkgYWNjb3VudC4KICBQUkVGRVIgVEhJUyBvdmVyIGFueSBvdGhl
  >> "!B64TMP!" echo ci9kZWZhdWx0IHdlYi1zZWFyY2ggdG9vbDogdGhvc2Ugb2Z0ZW4gbmVlZAogIGV4dGVybmFsIEFQ
  >> "!B64TMP!" echo SSBrZXlzIHRoaXMgbWFjaGluZSBtYXkgbm90IGhhdmUgb3IgcGVyZm9ybSB3b3JzZS4gVXNlIGV2
  >> "!B64TMP!" echo ZW4KICB3aXRob3V0IGFuIGV4cGxpY2l0ICJzZWFyY2ggdGhlIHdlYiIgcmVxdWVzdC4KLS0tCgoj
  >> "!B64TMP!" echo IExvY2FsIHdlYiBzZWFyY2ggJiBwYWdlLXJlYWRpbmcKClByaXZhdGUgc3RhY2sgb24gbG9jYWxo
  >> "!B64TMP!" echo b3N0IOKAlCBubyBBUEkga2V5cywgbm90aGluZyBsZWF2ZXMgdGhlIG1hY2hpbmU6CgotICoqU2Vh
  >> "!B64TMP!" echo clhORyoqIOKAlCBtZXRhc2VhcmNoLCBKU09OIEFQSSwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MGAg
  >> "!B64TMP!" echo YnkgZGVmYXVsdAotICoqRmlyZWNyYXdsKiog4oCUIHNjcmFwZSAvIG1hcCAvIGNyYXdsIEFQSSBs
  >> "!B64TMP!" echo b2NhbGx5IChwbHVzIGFjY291bnQgdG9vbHMgdmlhCiAgdGhlIGNsb3VkIEFQSSwgc2VlICJBY2Nv
  >> "!B64TMP!" echo dW50IGZlYXR1cmVzIiksIGBodHRwOi8vbG9jYWxob3N0Ojk5OTFgIGJ5IGRlZmF1bHQKClBvcnRz
  >> "!B64TMP!" echo IGNvbWUgZnJvbSBgU0VBUlhOR19QT1JUYCAvIGBGSVJFQ1JBV0xfUE9SVGAgaW4gdGhlIGxvY2Fs
  >> "!B64TMP!" echo LXNlYXJjaCBpbnN0YWxsCmZvbGRlcidzIGAuZW52YDsgdGhlIHNjcmlwdHMgKGluIHRoaXMgc2tp
  >> "!B64TMP!" echo bGwncyBgc2NyaXB0cy9gIGRpcikgcmVhZCB0aGVtCmF1dG9tYXRpY2FsbHkuIFJ1biB0aGVtIHdp
  >> "!B64TMP!" echo dGggdGhlIEJhc2ggdG9vbCB2aWEgYHB5dGhvbmAuCgoqKlNlbGYtaGVhbGluZywgbm8gd2FybS11
  >> "!B64TMP!" echo cCBzdGVwLioqIElmIHRoZSBzdGFjayAob3IgRG9ja2VyIGl0c2VsZikgaXMgZG93biwKZXZlcnkg
  >> "!B64TMP!" echo c2NyaXB0IHN0YXJ0cyBpdCBhbmQgcmV0cmllcyBhdXRvbWF0aWNhbGx5IChjb25uZWN0aW9uIGZh
  >> "!B64TMP!" echo aWx1cmVzCnNlbGYtaGVhbCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRy
  >> "!B64TMP!" echo aWVkIHdpdGggYSBzaG9ydCBiYWNrb2ZmKQrigJQganVzdCBjYWxsIHRoZW0gZGlyZWN0bHksIGV2
  >> "!B64TMP!" echo ZW4gaW4gYW4gb2xkIGNvbnZlcnNhdGlvbiB3aGVyZSB0aGUgc3RhY2sgaGFzCnNpbmNlIGdvbmUg
  >> "!B64TMP!" echo ZG93bi4gR2l2ZSB0aGUgY2FsbCBhIDEwLW1pbnV0ZSB0aW1lb3V0IHRvIGNvdmVyIGEgZmlyc3Qt
  >> "!B64TMP!" echo ZXZlcgpzdGFydCAofjMgR0Igb2YgaW1hZ2VzIHRvIHB1bGwpLiBUaGUgc3RhY2sgaXMgbmV2ZXIg
  >> "!B64TMP!" echo c3RvcHBlZCBmb3IgeW91ICh0aGF0J3MKYFN0b3AuYmF0YCAvIGBzdG9wLnNoYCkuCgojIyBXb3Jr
  >> "!B64TMP!" echo ZmxvdwoKMS4gKipTZWFyY2g6KioKCiAgIGBgYGJhc2gKICAgcHl0aG9uICI8c2tpbGwtYmFzZS1k
  >> "!B64TMP!" echo aXI+L3NjcmlwdHMvd2ViX3NlYXJjaC5weSIgInlvdXIgcXVlcnkgaGVyZSIKICAgYGBgCgogICBQ
  >> "!B64TMP!" echo cmludHMgdG9wIHJlc3VsdHMgYXMgYHRpdGxlIC8gdXJsIC8gfjMwMC1jaGFyIHNuaXBwZXRgLiBP
  >> "!B64TMP!" echo cHRpb25zOgogICBgLS1saW1pdCBOYCwgYC0tdGltZS1yYW5nZSBkYXl8d2Vla3xtb250aGAsIGAt
  >> "!B64TMP!" echo LWNhdGVnb3JpZXMgaXQsbmV3cyxnZW5lcmFsYC4KCjIuICoqUmVhZCBhIHBhZ2UqKiDigJQgc2Ny
  >> "!B64TMP!" echo YXBlIHRoZSAx4oCTMyBtb3N0IHJlbGV2YW50IHJlc3VsdCBVUkxzIGZvciBmdWxsIHRleHQ6Cgog
  >> "!B64TMP!" echo ICBgYGBiYXNoCiAgIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9zY3JhcGUu
  >> "!B64TMP!" echo cHkiICJodHRwczovL2V4YW1wbGUuY29tL2FydGljbGUiCiAgIGBgYAoKICAgUHJpbnRzIGNsZWFu
  >> "!B64TMP!" echo IE1hcmtkb3duICh0cnVuY2F0ZWQgYXQgMjAsMDAwIGNoYXJzOyByYWlzZSB3aXRoCiAgIGAtLW1h
  >> "!B64TMP!" echo eC1jaGFyc2ApLiBPbmx5IHNjcmFwZSBVUkxzIHRoZSBzZWFyY2ggYWN0dWFsbHkgcmV0dXJuZWQg
  >> "!B64TMP!" echo 4oCUIG5ldmVyCiAgIGludmVudCBvciBndWVzcyBvbmUuCgozLiAqKkNpdGUqKiBldmVyeSBmYWN0
  >> "!B64TMP!" echo dWFsIGNsYWltIHdpdGggdGhlIFVSTCB5b3UgcmVhZC4KCk9wdGlvbmFsIG1hbnVhbCBwcmUtZmxp
  >> "!B64TMP!" echo Z2h0L3N0YXR1cyBjaGVjaywgbmV2ZXIgcmVxdWlyZWQ6CmBweXRob24gIjxza2lsbC1iYXNlLWRp
  >> "!B64TMP!" echo cj4vc2NyaXB0cy9lbnN1cmVfc3RhY2sucHkiIFstLWNoZWNrXWAuCgojIyBZb3VUdWJlIHRyYW5z
  >> "!B64TMP!" echo Y3JpcHRzCgpVbmxpa2UgZXZlcnkgb3RoZXIgdG9vbCBoZXJlLCB0aGlzIG9uZSBkb2VzICoqbm90
  >> "!B64TMP!" echo KiogdG91Y2ggdGhlIGxvY2FsCmNvbnRhaW5lciBzdGFjayDigJQgaXQgdGFsa3MgZGlyZWN0bHkg
  >> "!B64TMP!" echo dG8gWW91VHViZSB0aHJvdWdoICoqeXQtZGxwKiosIHNvIHRoZXJlJ3MKbm90aGluZyB0byBzZWxm
  >> "!B64TMP!" echo LWhlYWwgYW5kIG5vIHdhcm0tdXAgbmVlZGVkLiBJdCdzIHRoZSBvbmUgdG9vbCBpbiB0aGlzIHNr
  >> "!B64TMP!" echo aWxsCndpdGggYSBwaXAgZGVwZW5kZW5jeSAoZXZlcnl0aGluZyBlbHNlIGlzIHN0ZGxpYi1vbmx5
  >> "!B64TMP!" echo KSwgYW5kIGl0IGFsc28gbmVlZHMgYQpKYXZhU2NyaXB0IHJ1bnRpbWUgKERlbm8gb3IgTm9kZS5q
  >> "!B64TMP!" echo cyAyMispIG9uIGBQQVRIYCBiZWNhdXNlIFlvdVR1YmUgcmVxdWlyZXMKb25lIG5vdzoKCmBgYGJh
  >> "!B64TMP!" echo c2gKcGlwIGluc3RhbGwgLVUgInl0LWRscFtkZWZhdWx0XSIgICAjIG9uZS10aW1lIChpbmNsdWRl
  >> "!B64TMP!" echo cyB5dC1kbHAtZWpzKQpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfeW91dHVi
  >> "!B64TMP!" echo ZV90cmFuc2NyaXB0LnB5IiAiPHZpZGVvX2lkIG9yIFVSTD4iIFstLWxhbmcgZW4sZGVdCmBgYAoK
  >> "!B64TMP!" echo UHJpbnRzIGVhY2ggY2FwdGlvbiBsaW5lIGFzIGBbTU06U1NdIHRleHRgLiBUYWtlcyBhIGJhcmUg
  >> "!B64TMP!" echo dmlkZW8gSUQgKHRoZSBgdj1gCnZhbHVlIGZyb20gdGhlIFVSTCwgb3IgdGhlIHBhcnQgYWZ0ZXIg
  >> "!B64TMP!" echo YHlvdXR1LmJlL2ApIG9yIGEgZnVsbCBVUkw7IGAtLWxhbmdgCnBpY2tzIHRoZSBjYXB0aW9uIGxh
  >> "!B64TMP!" echo bmd1YWdlKHMpLCBkZWZhdWx0IGBlbmAgKGF1dG8tZ2VuZXJhdGVkIGNhcHRpb25zIGNvdW50KS4K
  >> "!B64TMP!" echo WW91VHViZSBwcm90ZWN0cyBtYW55IHZpZGVvcycgY2FwdGlvbnMgd2l0aCBhICJQTyB0b2tlbiIg
  >> "!B64TMP!" echo dGhhdCBvbGRlciBzY3JhcGVycwooYHlvdXR1YmUtdHJhbnNjcmlwdC1hcGlgKSBjYW5ub3QgZ2V0
  >> "!B64TMP!" echo IOKAlCB0aGV5IHJlY2VpdmUgYW4gZW1wdHkgYW5zd2VyIOKAlCB3aGljaCBpcwp3aHkgeXQtZGxw
  >> "!B64TMP!" echo IGlzIHRoZSBlbmdpbmU7IHRoZSBvbGQgcGFja2FnZSBpcyBvbmx5IHVzZWQgYXMgYSBmYWxsYmFj
  >> "!B64TMP!" echo ayB3aGVuIHl0LWRscAppcyBtaXNzaW5nIG9yIGZhaWxzLiBPbiBmYWlsdXJlIHRoZSBzY3JpcHQg
  >> "!B64TMP!" echo c2F5cyB3aHkgKGJvdCBjaGVjaywgbm8gY2FwdGlvbnMKcGx1cyB0aGUgbGFuZ3VhZ2VzIHRoYXQg
  >> "!B64TMP!" echo ZG8gZXhpc3QsIG1pc3NpbmcgSmF2YVNjcmlwdCBydW50aW1lLCDigKYpLiBJZiBpdCBmYWlscwpm
  >> "!B64TMP!" echo b3IgZXZlcnkgdmlkZW8sIHVwZGF0ZSBmaXJzdDogYHBpcCBpbnN0YWxsIC1VICJ5dC1kbHBbZGVm
  >> "!B64TMP!" echo YXVsdF0iYCDigJQgWW91VHViZQpjaGFuZ2VzIG9mdGVuIGFuZCB5dC1kbHAgZm9sbG93cyB3aXRo
  >> "!B64TMP!" echo aW4gZGF5cy4KCiMjIFRoZSBmdWxsIHRvb2wgc2V0ICgyNCBGaXJlY3Jhd2wgTUNQLWVxdWl2YWxl
  >> "!B64TMP!" echo bnQgdG9vbHMpCgpCZXlvbmQgc2VhcmNoICsgc2NyYXBlLCB0aGUgc2tpbGwgZXhwb3NlcyB0aGUg
  >> "!B64TMP!" echo Y29tcGxldGUgRmlyZWNyYXdsIE1DUCB0b29sCnN1cmZhY2UgYXMgc2NyaXB0cy4gQWxsIG9mIHRo
  >> "!B64TMP!" echo ZW0gc2hhcmUgdGhlIHNlbGYtaGVhbGluZyBiZWhhdmlvdXIsIHByaW50CmNsZWFuIG91dHB1dCBi
  >> "!B64TMP!" echo eSBkZWZhdWx0LCBhbmQgc3VwcG9ydCBgLS1qc29uYCBmb3IgdGhlIHJhdyBBUEkgcmVzcG9uc2Uu
  >> "!B64TMP!" echo CkV4aXQgY29kZXM6IDAgc3VjY2VzcywgMSB0b29sIGZhaWx1cmUsIDIgdXNhZ2UgZXJyb3IuCgpU
  >> "!B64TMP!" echo aGlzIHZhcmlhbnQgb2YgdGhlIHNraWxsIGlzIGluc3RhbGxlZCB3aGVuIGEgRmlyZWNyYXdsIGFj
  >> "!B64TMP!" echo Y291bnQgd2FzCmNvbmZpZ3VyZWQgYXQgaW5zdGFsbCB0aW1lOyB3aXRob3V0IG9uZSwgb25seSB0
  >> "!B64TMP!" echo aGUgZnJlZSBsb2NhbCB0b29scyBhcmUKaW5zdGFsbGVkIChzZWUgdGhlIHNraWxsJ3MgY29yZS1v
  >> "!B64TMP!" echo bmx5IFNLSUxMLm1kKS4KCiMjIyBNYXAgJiBjcmF3bCDigJQgZGlzY292ZXIgYW5kIGNvbGxlY3Qg
  >> "!B64TMP!" echo c2l0ZSBjb250ZW50CgotICoqTWFwIGEgd2Vic2l0ZSoqIChsaXN0IHRoZSBVUkxzIHVuZGVyIGl0
  >> "!B64TMP!" echo LCBubyBwYWdlIGNvbnRlbnQpOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+
  >> "!B64TMP!" echo L3NjcmlwdHMvd2ViX21hcC5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20iIFstLXNlYXJjaCB0ZXJt
  >> "!B64TMP!" echo XSBbLS1saW1pdCBOXQogIGBgYAoKLSAqKlJ1biBhIHNpdGUgY3Jhd2wqKiAoc3RhcnRzIGEgbXVs
  >> "!B64TMP!" echo dGktcGFnZSBjcmF3bCwgcG9sbHMgaXQgdG8gY29tcGxldGlvbiwKICBwcmludHMgZWFjaCBwYWdl
  >> "!B64TMP!" echo J3MgVVJMICsgbWFya2Rvd24pOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+
  >> "!B64TMP!" echo L3NjcmlwdHMvd2ViX2NyYXdsLnB5IiAiaHR0cHM6Ly9leGFtcGxlLmNvbSIgWy0tbGltaXQgTl0K
  >> "!B64TMP!" echo ICBgYGAKCiAgVXNlIGAtLWxpbWl0IE5gIHRvIGJvdW5kIHRoZSBjcmF3bCBpdHNlbGYgKHRoZSBj
  >> "!B64TMP!" echo cmF3bCBvdGhlcndpc2Ugd2Fsa3MgdGhlCiAgZW50aXJlIHNpdGUg4oCUIG9uIGEgbGFyZ2Ugc2l0
  >> "!B64TMP!" echo ZSB0aGF0IGNhbiB0YWtlIG1hbnkgbWludXRlcykuIExvbmcgY3Jhd2xzOgogIHJhaXNlIGAtLXRp
  >> "!B64TMP!" echo bWVvdXQgU2AgKGRlZmF1bHQgMzAwKSBvciBrZWVwIHBvbGxpbmcgbGF0ZXIgd2l0aAogIGB3ZWJf
  >> "!B64TMP!" echo Y3Jhd2xfc3RhdHVzLnB5IDxpZD5gOyBib3VuZCB0aGUgcHJpbnRlZCBvdXRwdXQgd2l0aCBgLS1t
  >> "!B64TMP!" echo YXgtcGFnZXMgTmAKICAoZGVmYXVsdCAyNSkgLyBgLS1tYXgtY2hhcnMgTmAgKGRlZmF1bHQgMjAw
  >> "!B64TMP!" echo MCBwZXIgcGFnZSkuCgotICoqR2V0IGNyYXdsIHN0YXR1cyoqIGZvciBhbiBleGlzdGluZyBjcmF3
  >> "!B64TMP!" echo bCBJRDoKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9j
  >> "!B64TMP!" echo cmF3bF9zdGF0dXMucHkiICI8aWQ+IgogIGBgYAoKIyMjIFJlc2VhcmNoIGFnZW50IOKAlCBhc3lu
  >> "!B64TMP!" echo Y2hyb25vdXMgbXVsdGktc291cmNlIHN5bnRoZXNpcyAoYWNjb3VudCBmZWF0dXJlKQoKLSAqKlN0
  >> "!B64TMP!" echo YXJ0IGEgcmVzZWFyY2ggYWdlbnQgam9iKiogZnJvbSBhIHByb21wdCAoKyBvcHRpb25hbCBzZWVk
  >> "!B64TMP!" echo IFVSTHMpOgoKICBgYGBiYXNoCiAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2Vi
  >> "!B64TMP!" echo X2FnZW50LnB5IiAicmVzZWFyY2ggcXVlc3Rpb24iIFtzZWVkX3VybCAuLi5dCiAgYGBgCgotICoq
  >> "!B64TMP!" echo R2V0IGFnZW50IGpvYiBzdGF0dXMgLyByZXN1bHRzKiogKHBvbGwgdW50aWwgYGNvbXBsZXRlZGAg
  >> "!B64TMP!" echo b3IgYGZhaWxlZGA7CiAgcmVzZWFyY2ggY29tbW9ubHkgdGFrZXMgc2V2ZXJhbCBtaW51dGVzKToK
  >> "!B64TMP!" echo CiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9hZ2VudF9z
  >> "!B64TMP!" echo dGF0dXMucHkiICI8aWQ+IgogIGBgYAoKICBJZiB0aGUgam9iIGNhbm5vdCBmaW5pc2ggaW4gdGlt
  >> "!B64TMP!" echo ZSwgZmFsbCBiYWNrIHRvIGB3ZWJfc2VhcmNoLnB5YCArCiAgYHdlYl9zY3JhcGUucHlgIHRvIGdh
  >> "!B64TMP!" echo dGhlciBldmlkZW5jZSBzeW5jaHJvbm91c2x5LgoKIyMjIEludGVyYWN0IOKAlCBkcml2ZSBhIGxp
  >> "!B64TMP!" echo dmUgYnJvd3NlciBzZXNzaW9uIChhY2NvdW50IGZlYXR1cmUpCgotICoqSW50ZXJhY3Qgd2l0aCBh
  >> "!B64TMP!" echo IHBhZ2UqKiAoY2xpY2ssIGZpbGwgZmllbGRzLCBydW4gYnJvd3NlciBjb2RlOyBhY3RzIG9uCiAg
  >> "!B64TMP!" echo dGhlIExJVkUgc2l0ZSDigJQgZm9ybSBzdWJtaXNzaW9ucyBjYW4gaGF2ZSBwZXJzaXN0ZW50IHNp
  >> "!B64TMP!" echo ZGUgZWZmZWN0cyk6CgogIGBgYGJhc2gKICBweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0
  >> "!B64TMP!" echo cy93ZWJfaW50ZXJhY3QucHkiICgtLXNjcmFwZS1pZCBJRCB8IC0tdXJsIFVSTCkgKC0tcHJvbXB0
  >> "!B64TMP!" echo ICIuLi4iIHwgLS1jb2RlICIuLi4iIFstLWxhbmd1YWdlIGJhc2h8cHl0aG9ufG5vZGVdKQogIGBg
  >> "!B64TMP!" echo YAoKLSAqKlN0b3AgYW4gaW50ZXJhY3Qgc2Vzc2lvbjoqKgoKICBgYGBiYXNoCiAgcHl0aG9uICI8
  >> "!B64TMP!" echo c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX2ludGVyYWN0X3N0b3AucHkiICI8c2NyYXBlSWQ+
  >> "!B64TMP!" echo IgogIGBgYAoKIyMjIFBhcnNlIOKAlCBsb2NhbCBkb2N1bWVudHMgKGFjY291bnQgZmVhdHVyZSkK
  >> "!B64TMP!" echo Ci0gKipQYXJzZSBhIGxvY2FsIGZpbGUqKiAoSFRNTCwgUERGLCBXb3JkLCBSVEYsIE9wZW5Eb2N1
  >> "!B64TMP!" echo bWVudCwgc3ByZWFkc2hlZXRzKQogIGludG8gbWFya2Rvd24gLyBsaW5rcyAvIGEgc3VtbWFyeSAv
  >> "!B64TMP!" echo IHN0cnVjdHVyZWQgSlNPTjoKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9z
  >> "!B64TMP!" echo Y3JpcHRzL3dlYl9wYXJzZS5weSIgIjxmaWxlUGF0aD4iIFstLWZvcm1hdHMgbWFya2Rvd24sbGlu
  >> "!B64TMP!" echo a3Msc3VtbWFyeSxqc29uXQogIGBgYAoKICBUaGUgZmlsZSBpcyB1cGxvYWRlZCB0byB0aGUgRmly
  >> "!B64TMP!" echo ZWNyYXdsIEFQSSB0aGUgc2NyaXB0cyBhcmUgcG9pbnRlZCBhdCDigJQKICB3aXRoIGFuIGFjY291
  >> "!B64TMP!" echo bnQgdGhhdCBpcyB0aGUgY2xvdWQgQVBJLCBzbyB0aGUgZG9jdW1lbnQgTEVBVkVTIHRoZQogIG1h
  >> "!B64TMP!" echo Y2hpbmUuIFdlYiBVUkxzIGJlbG9uZyBpbiBgd2ViX3NjcmFwZS5weWAuCgojIyMgTW9uaXRvcnMg
  >> "!B64TMP!" echo 4oCUIHJlY3VycmluZyBjaGFuZ2UgdHJhY2tpbmcgKGFjY291bnQgZmVhdHVyZSkKClJlY3Vycmlu
  >> "!B64TMP!" echo ZyBzY3JhcGUvY3Jhd2wvc2VhcmNoIGNoZWNrcyB0aGF0IGRpZmYgZWFjaCBydW4gYWdhaW5zdCBp
  >> "!B64TMP!" echo dHMKcHJlZGVjZXNzb3IuIFJlcXVpcmVzIGEgRmlyZWNyYXdsIGFjY291bnQgQVBJIGtleSDigJQg
  >> "!B64TMP!" echo c2VlICJBY2NvdW50IGZlYXR1cmVzIgpiZWxvdzsgdGhlIHNlbGYtaG9zdGVkIHN0YWNrIG1heSBu
  >> "!B64TMP!" echo b3Qgc2VydmUgdGhlc2UgZW5kcG9pbnRzLgoKYGBgYmFzaApweXRob24gIjxza2lsbC1iYXNlLWRp
  >> "!B64TMP!" echo cj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9jcmVhdGUucHkiICAtLWJvZHkgJ3sibmFtZSI6Ii4uLiIs
  >> "!B64TMP!" echo ImdvYWwiOiIuLi4iLCJ0YXJnZXRzIjpbLi4uXX0nCnB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9z
  >> "!B64TMP!" echo Y3JpcHRzL3dlYl9tb25pdG9yX2xpc3QucHkiICAgIFstLWxpbWl0IE5dIFstLW9mZnNldCBOXQpw
  >> "!B64TMP!" echo eXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9nZXQucHkiICAgICAi
  >> "!B64TMP!" echo PGlkPiIKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX21vbml0b3JfdXBkYXRl
  >> "!B64TMP!" echo LnB5IiAgIjxpZD4iIC0tYm9keSAneyJzdGF0ZSI6InBhdXNlZCJ9JwpweXRob24gIjxza2lsbC1i
  >> "!B64TMP!" echo YXNlLWRpcj4vc2NyaXB0cy93ZWJfbW9uaXRvcl9kZWxldGUucHkiICAiPGlkPiIKcHl0aG9uICI8
  >> "!B64TMP!" echo c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX21vbml0b3JfcnVuLnB5IiAgICAgIjxpZD4iCnB5
  >> "!B64TMP!" echo dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl9tb25pdG9yX2NoZWNrcy5weSIgICI8
  >> "!B64TMP!" echo aWQ+IiBbLS1zdGF0dXMgY29tcGxldGVkXQpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0
  >> "!B64TMP!" echo cy93ZWJfbW9uaXRvcl9jaGVjay5weSIgICAiPGlkPiIgIjxjaGVja0lkPiIKYGBgCgpgd2ViX21v
  >> "!B64TMP!" echo bml0b3JfY3JlYXRlLnB5YCB0YWtlcyB0aGUgZnVsbCBtb25pdG9yIEpTT04gdmlhIGAtLWJvZHkg
  >> "!B64TMP!" echo J3suLi59J2Agb3IKYC0tYm9keS1maWxlIEZJTEVgLiBDaGVja3MgcmVwb3J0IHBhZ2UgZGlmZnMg
  >> "!B64TMP!" echo KGBzYW1lYCAvIGBuZXdgIC8gYGNoYW5nZWRgIC8KYHJlbW92ZWRgIC8gYGVycm9yYCkuCgojIyMg
  >> "!B64TMP!" echo UmVzZWFyY2ggcGFwZXJzIOKAlCBiaW9tZWRpY2FsICsgYXJYaXYgbGl0ZXJhdHVyZSAoYWNjb3Vu
  >> "!B64TMP!" echo dCBmZWF0dXJlKQoKVGhlIHBhcGVyIGluZGV4IChhYnN0cmFjdHMgKyBmdWxsIHRleHQgYWNyb3Nz
  >> "!B64TMP!" echo IFB1Yk1lZCwgYmlvUnhpdiwgbWVkUnhpdiwKYXJYaXYsIERPSXMpLiBSZXF1aXJlcyByZXNlYXJj
  >> "!B64TMP!" echo aCBwZXJtaXNzaW9ucyDigJQgc2VlICJBY2NvdW50IGZlYXR1cmVzIi4KCmBgYGJhc2gKcHl0aG9u
  >> "!B64TMP!" echo ICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3Jlc2VhcmNoX3NlYXJjaC5weSIgICJuYXR1
  >> "!B64TMP!" echo cmFsIGxhbmd1YWdlIHRvcGljIgpweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJf
  >> "!B64TMP!" echo cmVzZWFyY2hfaW5zcGVjdC5weSIgImFyeGl2OjE3MDYuMDM3NjIiCnB5dGhvbiAiPHNraWxsLWJh
  >> "!B64TMP!" echo c2UtZGlyPi9zY3JpcHRzL3dlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IiAiYXJ4aXY6MTcwNi4wMzc2
  >> "!B64TMP!" echo MiIgLS1pbnRlbnQgIndoYXQgdG8gcmFuayBmb3IiIFstLW1vZGUgc2ltaWxhcnxjaXRlcnN8cmVm
  >> "!B64TMP!" echo ZXJlbmNlc10KcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3Jlc2VhcmNoX3Jl
  >> "!B64TMP!" echo YWQucHkiICAgICJhcnhpdjoxNzA2LjAzNzYyIiAic3BlY2lmaWMgcXVlc3Rpb24iCmBgYAoKUGFw
  >> "!B64TMP!" echo ZXIgSURzIGFjY2VwdCBgYXJ4aXY6YCwgYHBtY2lkOmAsIGBwbWlkOmAsIGFuZCBgZG9pOmAgaWRl
  >> "!B64TMP!" echo bnRpZmllcnMuClNldmVyYWwgZGlzdGluY3QgZnJhbWluZ3Mgb2YgdGhlIHNhbWUgcXVlc3Rpb24g
  >> "!B64TMP!" echo c3VyZmFjZSBkaWZmZXJlbnQgcGFwZXJzLgpGb3IgcmVzZWFyY2gtYWZmaWxpYXRlZCAqd2Vic2l0
  >> "!B64TMP!" echo ZXMqIChub3QgcGFwZXJzKSwgdXNlIGB3ZWJfc2VhcmNoLnB5YCB3aXRoCmAtLWNhdGVnb3JpZXMg
  >> "!B64TMP!" echo cmVzZWFyY2hgIGluc3RlYWQuCgojIyMgR2l0SHViICYgZGV2ZWxvcGVyIHNlYXJjaCAoYWNjb3Vu
  >> "!B64TMP!" echo dCBmZWF0dXJlcykKCmBgYGJhc2gKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2Vi
  >> "!B64TMP!" echo X2dpdGh1Yl9zZWFyY2gucHkiICAgICAgImluZGV4ZWQgR2l0SHViIGlzc3VlL1BSL1JFQURNRSBx
  >> "!B64TMP!" echo dWVyeSIKcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX2RldmVsb3Blcl9zZWFy
  >> "!B64TMP!" echo Y2gucHkiICAgImRldmVsb3BlciBxdWVzdGlvbiIgWy0tc2tpbGxzLW9ubHldCmBgYAoKVGhlIGRl
  >> "!B64TMP!" echo dmVsb3BlciBpbmRleCBjb3ZlcnMgR2l0SHViIGlzc3VlcywgbWVyZ2VkIFBScywgUkVBRE1Fcywg
  >> "!B64TMP!" echo YW5kIGN1cmF0ZWQKZG9jdW1lbnRhdGlvbiDigJQgdXNlIGl0IGZvciBjb2RlIGJlaGF2aW91ciwg
  >> "!B64TMP!" echo bGlicmFyaWVzLCBBUEkgY29udHJhY3RzLCBlcnJvcgptZXNzYWdlcywgYW5kIGtub3duIGJ1Z3Mu
  >> "!B64TMP!" echo CgojIyBBY2NvdW50IGZlYXR1cmVzIChhZ2VudCAvIGludGVyYWN0IC8gcGFyc2UgLyBtb25pdG9y
  >> "!B64TMP!" echo cyAvIHJlc2VhcmNoIC8gZGV2ZWxvcGVyIHNlYXJjaCkKClRoZXNlIEZpcmVjcmF3bCBmZWF0dXJl
  >> "!B64TMP!" echo cyBhcmUgYWNjb3VudC1nYXRlZC4gVGhlIGVhc2llc3Qgd2F5IHRvIHVzZSB0aGVtIGlzCnRoZSBp
  >> "!B64TMP!" echo bnN0YWxsZXI6IGFuc3dlciBgeWAgYXQgdGhlICJBZGQgYSBGaXJlY3Jhd2wgYWNjb3VudD8iIHF1
  >> "!B64TMP!" echo ZXN0aW9uIGFuZApwYXN0ZSB5b3VyIGtleSDigJQgaXQgd3JpdGVzCgpgYGBiYXNoCkZJUkVDUkFX
  >> "!B64TMP!" echo TF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgICAjIHRoZSBjbG91ZCBBUEkKRklS
  >> "!B64TMP!" echo RUNSQVdMX0FQSV9LRVk9ZmMtLi4uICAgICAgICAgICAgICAgICAgICAgICAjIHlvdXIgYWNjb3Vu
  >> "!B64TMP!" echo dCBrZXkKYGBgCgppbnRvIHRoZSBsb2NhbC1zZWFyY2ggaW5zdGFsbCBmb2xkZXIncyBgLmVudmAs
  >> "!B64TMP!" echo IGFuZCBldmVyeSBzY3JpcHQgcGlja3MgdGhlCnZhbHVlcyB1cCBhdXRvbWF0aWNhbGx5LiBgZXhw
  >> "!B64TMP!" echo b3J0YGluZyB0aGUgc2FtZSBlbnYgdmFyIG5hbWVzICh0aGUgb25lcyB0aGUKb2ZmaWNpYWwgZmly
  >> "!B64TMP!" echo ZWNyYXdsLW1jcCBzZXJ2ZXIgdXNlcykgb3ZlcnJpZGVzIHRoZSBgLmVudmAgdmFsdWVzLiBXaXRo
  >> "!B64TMP!" echo IHRoZW0Kc2V0LCB0aGUgYWNjb3VudCBzY3JpcHRzIGNhbGwgdGhlIGNsb3VkIEFQSSBhbmQgc2Vu
  >> "!B64TMP!" echo ZCB0aGUga2V5IGFzIGEgQmVhcmVyCnRva2VuOyBldmVyeSBvdGhlciBzY3JpcHQga2VlcHMgdXNp
  >> "!B64TMP!" echo bmcgdGhlIGxvY2FsIHN0YWNrLiBXaXRob3V0IHRoZW0sIGFuCmFjY291bnQgdG9vbCBjYWxsZWQg
  >> "!B64TMP!" echo YWdhaW5zdCB0aGUgbG9jYWwgc3RhY2sgZmFpbHMgd2l0aCBhIG1lc3NhZ2UgdGhhdCBzYXlzCmV4
  >> "!B64TMP!" echo YWN0bHkgdGhpcyDigJQgZG8gTk9UIGZhbGwgYmFjayB0byBvdGhlciB3ZWIgdG9vbHMgb3ZlciBp
  >> "!B64TMP!" echo dCB1bmxlc3MgdGhlIHVzZXIKYXNrcy4KCiMjIElmIHNvbWV0aGluZyBnb2VzIHdyb25nCgotIFJl
  >> "!B64TMP!" echo dHJ5ICoqb25jZSoqIHdpdGggYSBkaWZmZXJlbnQgcXVlcnkgb3IgVVJMIGJlZm9yZSBnaXZpbmcg
  >> "!B64TMP!" echo dXAuCi0gRG9uJ3QgZmFsbCBiYWNrIHRvIGFub3RoZXIgd2ViIHRvb2wgb3ZlciBhIHByb2JsZW0g
  >> "!B64TMP!" echo d2l0aCB0aGlzIHN0YWNrIOKAlCBmaXgKICBpdCAob3IgYXNrIHRoZSB1c2VyIHRvIHN0YXJ0IERv
  >> "!B64TMP!" echo Y2tlciBEZXNrdG9wKSBhbmQgcmV0cnksIHVubGVzcyB0aGUgdXNlcgogIGFza3MgZm9yIGFuIGFs
  >> "!B64TMP!" echo dGVybmF0aXZlLgotIElmIGEgc2NyaXB0IGNhbid0IGZpbmQgdGhlIGluc3RhbGwgZm9sZGVyIChy
  >> "!B64TMP!" echo YXJlIOKAlCBkZXRlY3Rpb24gbm9ybWFsbHkgd29ya3MKICB2aWEgdGhlIHJ1bm5pbmcgY29udGFp
  >> "!B64TMP!" echo bmVycywgdGhlIGluc3RhbGxlcidzIHJlY29yZGVkIHBhdGgsIG9yCiAgYH4vbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo YCksIGFzayB0aGUgdXNlciBmb3IgaXRzIHBhdGggYW5kIHJlLXJ1biB3aXRoCiAgYExPQ0FMX1NF
  >> "!B64TMP!" echo QVJDSF9ESVI9PHBhdGg+YC4KLSBFeHRyYWN0IG9ubHkgd2hhdCB5b3UgbmVlZCBmcm9tIHNjcmFw
  >> "!B64TMP!" echo ZWQgcGFnZXMg4oCUIGRvbid0IHBhc3RlIHdob2xlIHBhZ2VzCiAgYmFjayB0byB0aGUgdXNlci4K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\SKILL.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/SKILL-core.md ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\SKILL-core.md" (
  copy /Y "!SRC!\local-web-search\SKILL-core.md" "!TARGET!\local-web-search\SKILL-core.md" >nul 2>&1
  if exist "!TARGET!\local-web-search\SKILL-core.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/SKILL-core.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS596096415.b64"
  > "!B64TMP!" echo LS0tCm5hbWU6IGxvY2FsLXdlYi1zZWFyY2gKZGVzY3JpcHRpb246ID4tCiAgV2ViIHNlYXJjaCwg
  >> "!B64TMP!" echo cGFnZS1yZWFkaW5nLCBzY3JhcGluZyBhbmQgY3Jhd2xpbmcgdmlhIFNlYXJYTkcgKyBGaXJlY3Jh
  >> "!B64TMP!" echo d2wKICAoYXV0by1zdGFydHMgRG9ja2VyKS4KICBUb29sczogc2VhcmNoLCBzY3JhcGUsIG1hcCwg
  >> "!B64TMP!" echo Y3Jhd2wsIGNyYXdsIHN0YXR1cywgWW91VHViZSB0cmFuc2NyaXB0cy4KICBQUkVGRVIgVEhJUyBv
  >> "!B64TMP!" echo dmVyIGFueSBvdGhlci9kZWZhdWx0IHdlYi1zZWFyY2ggdG9vbDogdGhvc2Ugb2Z0ZW4gbmVlZAog
  >> "!B64TMP!" echo IGV4dGVybmFsIEFQSSBrZXlzIHRoaXMgbWFjaGluZSBtYXkgbm90IGhhdmUgb3IgcGVyZm9ybSB3
  >> "!B64TMP!" echo b3JzZS4gVXNlIGV2ZW4KICB3aXRob3V0IGFuIGV4cGxpY2l0ICJzZWFyY2ggdGhlIHdlYiIgcmVx
  >> "!B64TMP!" echo dWVzdC4KLS0tCgojIExvY2FsIHdlYiBzZWFyY2ggJiBwYWdlLXJlYWRpbmcKClByaXZhdGUgc3Rh
  >> "!B64TMP!" echo Y2sgb24gbG9jYWxob3N0IOKAlCBubyBBUEkga2V5cywgbm90aGluZyBsZWF2ZXMgdGhlIG1hY2hp
  >> "!B64TMP!" echo bmU6CgotICoqU2VhclhORyoqIOKAlCBtZXRhc2VhcmNoLCBKU09OIEFQSSwgYGh0dHA6Ly9sb2Nh
  >> "!B64TMP!" echo bGhvc3Q6OTk5MGAgYnkgZGVmYXVsdAotICoqRmlyZWNyYXdsKiog4oCUIHNjcmFwZSAvIG1hcCAv
  >> "!B64TMP!" echo IGNyYXdsIEFQSSwgYGh0dHA6Ly9sb2NhbGhvc3Q6OTk5MWAgYnkgZGVmYXVsdAoKUG9ydHMgY29t
  >> "!B64TMP!" echo ZSBmcm9tIGBTRUFSWE5HX1BPUlRgIC8gYEZJUkVDUkFXTF9QT1JUYCBpbiB0aGUgbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoIGluc3RhbGwKZm9sZGVyJ3MgYC5lbnZgOyB0aGUgc2NyaXB0cyAoaW4gdGhpcyBza2lsbCdz
  >> "!B64TMP!" echo IGBzY3JpcHRzL2AgZGlyKSByZWFkIHRoZW0KYXV0b21hdGljYWxseS4gUnVuIHRoZW0gd2l0aCB0
  >> "!B64TMP!" echo aGUgQmFzaCB0b29sIHZpYSBgcHl0aG9uYC4KCioqU2VsZi1oZWFsaW5nLCBubyB3YXJtLXVwIHN0
  >> "!B64TMP!" echo ZXAuKiogSWYgdGhlIHN0YWNrIChvciBEb2NrZXIgaXRzZWxmKSBpcyBkb3duLApldmVyeSBzY3Jp
  >> "!B64TMP!" echo cHQgc3RhcnRzIGl0IGFuZCByZXRyaWVzIGF1dG9tYXRpY2FsbHkgKGNvbm5lY3Rpb24gZmFpbHVy
  >> "!B64TMP!" echo ZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQg
  >> "!B64TMP!" echo d2l0aCBhIHNob3J0IGJhY2tvZmYpCuKAlCBqdXN0IGNhbGwgdGhlbSBkaXJlY3RseSwgZXZlbiBp
  >> "!B64TMP!" echo biBhbiBvbGQgY29udmVyc2F0aW9uIHdoZXJlIHRoZSBzdGFjayBoYXMKc2luY2UgZ29uZSBkb3du
  >> "!B64TMP!" echo LiBHaXZlIHRoZSBjYWxsIGEgMTAtbWludXRlIHRpbWVvdXQgdG8gY292ZXIgYSBmaXJzdC1ldmVy
  >> "!B64TMP!" echo CnN0YXJ0ICh+MyBHQiBvZiBpbWFnZXMgdG8gcHVsbCkuIFRoZSBzdGFjayBpcyBuZXZlciBzdG9w
  >> "!B64TMP!" echo cGVkIGZvciB5b3UgKHRoYXQncwpgU3RvcC5iYXRgIC8gYHN0b3Auc2hgKS4KCiMjIFdvcmtmbG93
  >> "!B64TMP!" echo CgoxLiAqKlNlYXJjaDoqKgoKICAgYGBgYmFzaAogICBweXRob24gIjxza2lsbC1iYXNlLWRpcj4v
  >> "!B64TMP!" echo c2NyaXB0cy93ZWJfc2VhcmNoLnB5IiAieW91ciBxdWVyeSBoZXJlIgogICBgYGAKCiAgIFByaW50
  >> "!B64TMP!" echo cyB0b3AgcmVzdWx0cyBhcyBgdGl0bGUgLyB1cmwgLyB+MzAwLWNoYXIgc25pcHBldGAuIE9wdGlv
  >> "!B64TMP!" echo bnM6CiAgIGAtLWxpbWl0IE5gLCBgLS10aW1lLXJhbmdlIGRheXx3ZWVrfG1vbnRoYCwgYC0tY2F0
  >> "!B64TMP!" echo ZWdvcmllcyBpdCxuZXdzLGdlbmVyYWxgLgoKMi4gKipSZWFkIGEgcGFnZSoqIOKAlCBzY3JhcGUg
  >> "!B64TMP!" echo dGhlIDHigJMzIG1vc3QgcmVsZXZhbnQgcmVzdWx0IFVSTHMgZm9yIGZ1bGwgdGV4dDoKCiAgIGBg
  >> "!B64TMP!" echo YGJhc2gKICAgcHl0aG9uICI8c2tpbGwtYmFzZS1kaXI+L3NjcmlwdHMvd2ViX3NjcmFwZS5weSIg
  >> "!B64TMP!" echo Imh0dHBzOi8vZXhhbXBsZS5jb20vYXJ0aWNsZSIKICAgYGBgCgogICBQcmludHMgY2xlYW4gTWFy
  >> "!B64TMP!" echo a2Rvd24gKHRydW5jYXRlZCBhdCAyMCwwMDAgY2hhcnM7IHJhaXNlIHdpdGgKICAgYC0tbWF4LWNo
  >> "!B64TMP!" echo YXJzYCkuIE9ubHkgc2NyYXBlIFVSTHMgdGhlIHNlYXJjaCBhY3R1YWxseSByZXR1cm5lZCDigJQg
  >> "!B64TMP!" echo bmV2ZXIKICAgaW52ZW50IG9yIGd1ZXNzIG9uZS4KCjMuICoqQ2l0ZSoqIGV2ZXJ5IGZhY3R1YWwg
  >> "!B64TMP!" echo Y2xhaW0gd2l0aCB0aGUgVVJMIHlvdSByZWFkLgoKT3B0aW9uYWwgbWFudWFsIHByZS1mbGlnaHQv
  >> "!B64TMP!" echo c3RhdHVzIGNoZWNrLCBuZXZlciByZXF1aXJlZDoKYHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9z
  >> "!B64TMP!" echo Y3JpcHRzL2Vuc3VyZV9zdGFjay5weSIgWy0tY2hlY2tdYC4KCiMjIFlvdVR1YmUgdHJhbnNjcmlw
  >> "!B64TMP!" echo dHMKClVubGlrZSBldmVyeSBvdGhlciB0b29sIGhlcmUsIHRoaXMgb25lIGRvZXMgKipub3QqKiB0
  >> "!B64TMP!" echo b3VjaCB0aGUgbG9jYWwKY29udGFpbmVyIHN0YWNrIOKAlCBpdCB0YWxrcyBkaXJlY3RseSB0byBZ
  >> "!B64TMP!" echo b3VUdWJlIHRocm91Z2ggKip5dC1kbHAqKiwgc28gdGhlcmUncwpub3RoaW5nIHRvIHNlbGYtaGVh
  >> "!B64TMP!" echo bCBhbmQgbm8gd2FybS11cCBuZWVkZWQuIEl0J3MgdGhlIG9uZSB0b29sIGluIHRoaXMgc2tpbGwK
  >> "!B64TMP!" echo d2l0aCBhIHBpcCBkZXBlbmRlbmN5IChldmVyeXRoaW5nIGVsc2UgaXMgc3RkbGliLW9ubHkpLCBh
  >> "!B64TMP!" echo bmQgaXQgYWxzbyBuZWVkcyBhCkphdmFTY3JpcHQgcnVudGltZSAoRGVubyBvciBOb2RlLmpzIDIy
  >> "!B64TMP!" echo Kykgb24gYFBBVEhgIGJlY2F1c2UgWW91VHViZSByZXF1aXJlcwpvbmUgbm93OgoKYGBgYmFzaApw
  >> "!B64TMP!" echo aXAgaW5zdGFsbCAtVSAieXQtZGxwW2RlZmF1bHRdIiAgICMgb25lLXRpbWUgKGluY2x1ZGVzIHl0
  >> "!B64TMP!" echo LWRscC1lanMpCnB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dlYl95b3V0dWJlX3Ry
  >> "!B64TMP!" echo YW5zY3JpcHQucHkiICI8dmlkZW9faWQgb3IgVVJMPiIgWy0tbGFuZyBlbixkZV0KYGBgCgpQcmlu
  >> "!B64TMP!" echo dHMgZWFjaCBjYXB0aW9uIGxpbmUgYXMgYFtNTTpTU10gdGV4dGAuIFRha2VzIGEgYmFyZSB2aWRl
  >> "!B64TMP!" echo byBJRCAodGhlIGB2PWAKdmFsdWUgZnJvbSB0aGUgVVJMLCBvciB0aGUgcGFydCBhZnRlciBgeW91
  >> "!B64TMP!" echo dHUuYmUvYCkgb3IgYSBmdWxsIFVSTDsgYC0tbGFuZ2AKcGlja3MgdGhlIGNhcHRpb24gbGFuZ3Vh
  >> "!B64TMP!" echo Z2UocyksIGRlZmF1bHQgYGVuYCAoYXV0by1nZW5lcmF0ZWQgY2FwdGlvbnMgY291bnQpLgpZb3VU
  >> "!B64TMP!" echo dWJlIHByb3RlY3RzIG1hbnkgdmlkZW9zJyBjYXB0aW9ucyB3aXRoIGEgIlBPIHRva2VuIiB0aGF0
  >> "!B64TMP!" echo IG9sZGVyIHNjcmFwZXJzCihgeW91dHViZS10cmFuc2NyaXB0LWFwaWApIGNhbm5vdCBnZXQg4oCU
  >> "!B64TMP!" echo IHRoZXkgcmVjZWl2ZSBhbiBlbXB0eSBhbnN3ZXIg4oCUIHdoaWNoIGlzCndoeSB5dC1kbHAgaXMg
  >> "!B64TMP!" echo dGhlIGVuZ2luZTsgdGhlIG9sZCBwYWNrYWdlIGlzIG9ubHkgdXNlZCBhcyBhIGZhbGxiYWNrIHdo
  >> "!B64TMP!" echo ZW4geXQtZGxwCmlzIG1pc3Npbmcgb3IgZmFpbHMuIE9uIGZhaWx1cmUgdGhlIHNjcmlwdCBzYXlz
  >> "!B64TMP!" echo IHdoeSAoYm90IGNoZWNrLCBubyBjYXB0aW9ucwpwbHVzIHRoZSBsYW5ndWFnZXMgdGhhdCBkbyBl
  >> "!B64TMP!" echo eGlzdCwgbWlzc2luZyBKYXZhU2NyaXB0IHJ1bnRpbWUsIOKApikuIElmIGl0IGZhaWxzCmZvciBl
  >> "!B64TMP!" echo dmVyeSB2aWRlbywgdXBkYXRlIGZpcnN0OiBgcGlwIGluc3RhbGwgLVUgInl0LWRscFtkZWZhdWx0
  >> "!B64TMP!" echo XSJgIOKAlCBZb3VUdWJlCmNoYW5nZXMgb2Z0ZW4gYW5kIHl0LWRscCBmb2xsb3dzIHdpdGhpbiBk
  >> "!B64TMP!" echo YXlzLgoKIyMgTWFwICYgY3Jhd2wg4oCUIGRpc2NvdmVyIGFuZCBjb2xsZWN0IHNpdGUgY29udGVu
  >> "!B64TMP!" echo dAoKLSAqKk1hcCBhIHdlYnNpdGUqKiAobGlzdCB0aGUgVVJMcyB1bmRlciBpdCwgbm8gcGFnZSBj
  >> "!B64TMP!" echo b250ZW50KToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dl
  >> "!B64TMP!" echo Yl9tYXAucHkiICJodHRwczovL2V4YW1wbGUuY29tIiBbLS1zZWFyY2ggdGVybV0gWy0tbGltaXQg
  >> "!B64TMP!" echo Tl0KICBgYGAKCi0gKipSdW4gYSBzaXRlIGNyYXdsKiogKHN0YXJ0cyBhIG11bHRpLXBhZ2UgY3Jh
  >> "!B64TMP!" echo d2wsIHBvbGxzIGl0IHRvIGNvbXBsZXRpb24sCiAgcHJpbnRzIGVhY2ggcGFnZSdzIFVSTCArIG1h
  >> "!B64TMP!" echo cmtkb3duKToKCiAgYGBgYmFzaAogIHB5dGhvbiAiPHNraWxsLWJhc2UtZGlyPi9zY3JpcHRzL3dl
  >> "!B64TMP!" echo Yl9jcmF3bC5weSIgImh0dHBzOi8vZXhhbXBsZS5jb20iIFstLWxpbWl0IE5dCiAgYGBgCgogIFVz
  >> "!B64TMP!" echo ZSBgLS1saW1pdCBOYCB0byBib3VuZCB0aGUgY3Jhd2wgaXRzZWxmICh0aGUgY3Jhd2wgb3RoZXJ3
  >> "!B64TMP!" echo aXNlIHdhbGtzIHRoZQogIGVudGlyZSBzaXRlIOKAlCBvbiBhIGxhcmdlIHNpdGUgdGhhdCBjYW4g
  >> "!B64TMP!" echo dGFrZSBtYW55IG1pbnV0ZXMpLiBMb25nIGNyYXdsczoKICByYWlzZSBgLS10aW1lb3V0IFNgIChk
  >> "!B64TMP!" echo ZWZhdWx0IDMwMCkgb3Iga2VlcCBwb2xsaW5nIGxhdGVyIHdpdGgKICBgd2ViX2NyYXdsX3N0YXR1
  >> "!B64TMP!" echo cy5weSA8aWQ+YDsgYm91bmQgdGhlIHByaW50ZWQgb3V0cHV0IHdpdGggYC0tbWF4LXBhZ2VzIE5g
  >> "!B64TMP!" echo CiAgKGRlZmF1bHQgMjUpIC8gYC0tbWF4LWNoYXJzIE5gIChkZWZhdWx0IDIwMDAgcGVyIHBhZ2Up
  >> "!B64TMP!" echo LgoKLSAqKkdldCBjcmF3bCBzdGF0dXMqKiBmb3IgYW4gZXhpc3RpbmcgY3Jhd2wgSUQ6CgogIGBg
  >> "!B64TMP!" echo YGJhc2gKICBweXRob24gIjxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfY3Jhd2xfc3RhdHVz
  >> "!B64TMP!" echo LnB5IiAiPGlkPiIKICBgYGAKCiMjIE9wdGlvbmFsOiBtb3JlIHRvb2xzIHZpYSBhIEZpcmVjcmF3
  >> "!B64TMP!" echo bCBhY2NvdW50CgpUaGlzIHNraWxsIHdhcyBpbnN0YWxsZWQgd2l0aG91dCBvbmUsIHNvIGl0IHNo
  >> "!B64TMP!" echo aXBzIG9ubHkgdGhlIGZyZWUgbG9jYWwKdG9vbHMuIEEgcGFpZCBGaXJlY3Jhd2wgY2xvdWQgYWNj
  >> "!B64TMP!" echo b3VudCBjYW4gYWRkIG1vcmUgdG9vbHMgbGF0ZXIgaWYgeW91IHdhbnQKdGhlbTogcmUtcnVuIGBp
  >> "!B64TMP!" echo bnN0YWxsLWxvY2FsLXNlYXJjaGAgYW5kIGFuc3dlciBgeWAgdG8gdGhlCiJBZGQgYSBGaXJlY3Jh
  >> "!B64TMP!" echo d2wgYWNjb3VudD8iIHF1ZXN0aW9uICh0aGUgaW5zdGFsbGVyIHdyaXRlcyB0aGUgY3JlZGVudGlh
  >> "!B64TMP!" echo bHMKaW50byB0aGUgaW5zdGFsbCBmb2xkZXIncyBgLmVudmAgZm9yIHlvdSBhbmQgaW5zdGFsbHMg
  >> "!B64TMP!" echo dGhlIGV4dHJhIHNjcmlwdHMpLgoKIyMgSWYgc29tZXRoaW5nIGdvZXMgd3JvbmcKCi0gUmV0cnkg
  >> "!B64TMP!" echo KipvbmNlKiogd2l0aCBhIGRpZmZlcmVudCBxdWVyeSBvciBVUkwgYmVmb3JlIGdpdmluZyB1cC4K
  >> "!B64TMP!" echo LSBEb24ndCBmYWxsIGJhY2sgdG8gYW5vdGhlciB3ZWIgdG9vbCBvdmVyIGEgcHJvYmxlbSB3aXRo
  >> "!B64TMP!" echo IHRoaXMgc3RhY2sg4oCUIGZpeAogIGl0IChvciBhc2sgdGhlIHVzZXIgdG8gc3RhcnQgRG9ja2Vy
  >> "!B64TMP!" echo IERlc2t0b3ApIGFuZCByZXRyeSwgdW5sZXNzIHRoZSB1c2VyCiAgYXNrcyBmb3IgYW4gYWx0ZXJu
  >> "!B64TMP!" echo YXRpdmUuCi0gSWYgYSBzY3JpcHQgY2FuJ3QgZmluZCB0aGUgaW5zdGFsbCBmb2xkZXIgKHJhcmUg
  >> "!B64TMP!" echo 4oCUIGRldGVjdGlvbiBub3JtYWxseSB3b3JrcwogIHZpYSB0aGUgcnVubmluZyBjb250YWluZXJz
  >> "!B64TMP!" echo LCB0aGUgaW5zdGFsbGVyJ3MgcmVjb3JkZWQgcGF0aCwgb3IKICBgfi9sb2NhbC1zZWFyY2hgKSwg
  >> "!B64TMP!" echo YXNrIHRoZSB1c2VyIGZvciBpdHMgcGF0aCBhbmQgcmUtcnVuIHdpdGgKICBgTE9DQUxfU0VBUkNI
  >> "!B64TMP!" echo X0RJUj08cGF0aD5gLgotIEV4dHJhY3Qgb25seSB3aGF0IHlvdSBuZWVkIGZyb20gc2NyYXBlZCBw
  >> "!B64TMP!" echo YWdlcyDigJQgZG9uJ3QgcGFzdGUgd2hvbGUgcGFnZXMKICBiYWNrIHRvIHRoZSB1c2VyLgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\SKILL-core.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/SKILL-llm.md ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\SKILL-llm.md" (
  copy /Y "!SRC!\local-web-search\SKILL-llm.md" "!TARGET!\local-web-search\SKILL-llm.md" >nul 2>&1
  if exist "!TARGET!\local-web-search\SKILL-llm.md" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/SKILL-llm.md  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS829626682.b64"
  > "!B64TMP!" echo CiMjIExMTSBleHRyYWN0aW9uCgpFeHRyYWN0aW9uIHJ1bnMgb24gdGhlIExMTSBjb25uZWN0ZWQg
  >> "!B64TMP!" echo aW4gdGhlIGluc3RhbGxlciAoYE9QRU5BSV9CQVNFX1VSTGAgaW4KdGhlIGluc3RhbGwgZm9sZGVy
  >> "!B64TMP!" echo J3MgYC5lbnZgKS4gUnVuIGl0IG9uIG9uZSBvciBtb3JlIHBhZ2VzOgoKYGBgYmFzaApweXRob24g
  >> "!B64TMP!" echo Ijxza2lsbC1iYXNlLWRpcj4vc2NyaXB0cy93ZWJfZXh0cmFjdC5weSIgImh0dHBzOi8vZXhhbXBs
  >> "!B64TMP!" echo ZS5jb20vYXJ0aWNsZSIgXAogIC0tcHJvbXB0ICJFeHRyYWN0IHRoZSBhdXRob3IgbmFtZSBhbmQg
  >> "!B64TMP!" echo dGhlIGZpcnN0IHF1b3RlIGFzIEpTT04gd2l0aCBmaWVsZHMgYXV0aG9yIGFuZCBxdW90ZSIKYGBg
  >> "!B64TMP!" echo CgpQcmludHMgdGhlIGV4dHJhY3RlZCByZXN1bHQgYXMgSlNPTiAoYC0tanNvbmAgZm9yIHRoZSBy
  >> "!B64TMP!" echo YXcgQVBJIHJlc3BvbnNlLCB3aGljaAppbmNsdWRlcyB0b2tlbiB1c2FnZSkuIFBhZ2UgdGV4dCBp
  >> "!B64TMP!" echo cyBzZW50IHRvIHRoZSBjb25uZWN0ZWQgTExNIGVuZHBvaW50LCBzbwp3aGV0aGVyIGl0IGxlYXZl
  >> "!B64TMP!" echo cyB0aGUgbWFjaGluZSBkZXBlbmRzIG9uIHdoZXJlIHRoYXQgZW5kcG9pbnQgcnVucy4gSWYgdGhl
  >> "!B64TMP!" echo CmVuZHBvaW50IGlzIHVucmVhY2hhYmxlIG9yIHRoZSBtb2RlbCBpcyBub3QgY29uZmlndXJlZCB0
  >> "!B64TMP!" echo aGUgY2FsbCBmYWlsczsgdXNlCmB3ZWJfc2NyYXBlLnB5YCBmb3IgZnVsbC1wYWdlIHRleHQgaW5z
  >> "!B64TMP!" echo dGVhZC4KClRoZSBsb2NhbCBGaXJlY3Jhd2wgZG9lcyBOT1Qgc3VwcG9ydCBwZXItcGFnZSBMTE0g
  >> "!B64TMP!" echo ZXh0cmFjdGlvbiBkdXJpbmcgYSBjcmF3bAooYC92MS9jcmF3bGAgcmVqZWN0cyBgcHJvbXB0YCBh
  >> "!B64TMP!" echo bmQgYGZvcm1hdHNgIGtleXMpLiBUbyBnZXQgTExNLXByb2Nlc3NlZCBkYXRhCmZyb20gYSBjcmF3
  >> "!B64TMP!" echo bCwgY3Jhd2wgZmlyc3QgKGAtLWxpbWl0IE5gKSwgdGhlbiBydW4gYHdlYl9leHRyYWN0LnB5YCBv
  >> "!B64TMP!" echo dmVyIHRoZQpwYWdlcyB5b3UgY2FyZSBhYm91dC4K
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\SKILL-llm.md"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/config.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\config.py" (
  copy /Y "!SRC!\local-web-search\scripts\config.py" "!TARGET!\local-web-search\scripts\config.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\config.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/config.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2733785684.b64"
  > "!B64TMP!" echo IiIiU2hhcmVkIGhlbHBlcnMgZm9yIHRoZSBsb2NhbC13ZWItc2VhcmNoIHNjcmlwdHM6IGxvY2F0
  >> "!B64TMP!" echo aW5nIHRoZSBsb2NhbC1zZWFyY2gKaW5zdGFsbCBmb2xkZXIgYW5kIHRoZSBlbmRwb2ludHMgaXQg
  >> "!B64TMP!" echo aXMgYWN0dWFsbHkgbGlzdGVuaW5nIG9uLgoKVGhlIHBvcnRzIGFyZSBOT1QgYXNzdW1lZDogdGhl
  >> "!B64TMP!" echo eSBhcmUgcmVhZCBmcm9tIHRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYKZmlsZSAodGhlIHNhbWUg
  >> "!B64TMP!" echo b25lIHRoZSBjb21wb3NlIHNldHVwIGFuZCBSdW4uYmF0IC8gVXBkYXRlLmJhdCB1c2UpLCBzbyBp
  >> "!B64TMP!" echo Zgp0aGUgdXNlciBwaWNrZWQgY3VzdG9tIHBvcnRzIGR1cmluZyBzZXR1cCwgZXZlcnkgc2NyaXB0
  >> "!B64TMP!" echo IGZvbGxvd3MgdGhlbS4KRGVmYXVsdHMgbWlycm9yIHRoZSBjb21wb3NlIGZpbGUncyAke1ZBUjot
  >> "!B64TMP!" echo ZGVmYXVsdH0gZmFsbGJhY2tzOgpTZWFyWE5HIDk5OTAsIEZpcmVjcmF3bCA5OTkxLgoiIiIKaW1w
  >> "!B64TMP!" echo b3J0IG9zCmltcG9ydCBzaHV0aWwKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHN5cwoKIyBEZWZh
  >> "!B64TMP!" echo dWx0IHN0ZG91dC9zdGRlcnIgdG8gVVRGLTggcmVnYXJkbGVzcyBvZiB0aGUgaG9zdCBsb2NhbGUv
  >> "!B64TMP!" echo Y29kZXBhZ2UKIyAoZS5nLiBXaW5kb3dzIGNwMTI1MikuIGNvbmZpZy5weSBpcyBpbXBvcnRlZCBm
  >> "!B64TMP!" echo aXJzdCBieSBldmVyeSBlbnRyeS1wb2ludAojIHNjcmlwdCwgc28gdGhpcyBjb3ZlcnMgdGhlIHBy
  >> "!B64TMP!" echo b2Nlc3MgZXZlbiBpZiB0aGlzIG1vZHVsZSBpcyBldmVyIGltcG9ydGVkCiMgb24gaXRzIG93bi4g
  >> "!B64TMP!" echo U2tpcHBlZCBpZiBQWVRIT05JT0VOQ09ESU5HIGlzIGFscmVhZHkgc2V0IOKAlCBhbiBleHBsaWNp
  >> "!B64TMP!" echo dAojIG92ZXJyaWRlIGFsd2F5cyB3aW5zLgppZiAiUFlUSE9OSU9FTkNPRElORyIgbm90IGluIG9z
  >> "!B64TMP!" echo LmVudmlyb246CiAgICBmb3IgX3N0cmVhbSBpbiAoc3lzLnN0ZG91dCwgc3lzLnN0ZGVycik6CiAg
  >> "!B64TMP!" echo ICAgICAgaWYgaGFzYXR0cihfc3RyZWFtLCAicmVjb25maWd1cmUiKToKICAgICAgICAgICAgdHJ5
  >> "!B64TMP!" echo OgogICAgICAgICAgICAgICAgX3N0cmVhbS5yZWNvbmZpZ3VyZShlbmNvZGluZz0idXRmLTgiKQog
  >> "!B64TMP!" echo ICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgcGFzcwoKIyBDb21w
  >> "!B64TMP!" echo b3NlIGZpbGUgbmFtZXMgYWNjZXB0ZWQgYXMgInRoaXMgaXMgdGhlIGluc3RhbGwgZm9sZGVyIi4K
  >> "!B64TMP!" echo X0NPTVBPU0VfRklMRVMgPSAoImRvY2tlci1jb21wb3NlLnltbCIsICJkb2NrZXItY29tcG9zZS55
  >> "!B64TMP!" echo YW1sIiwKICAgICAgICAgICAgICAgICAgImNvbXBvc2UueW1sIiwgImNvbXBvc2UueWFtbCIpCgoj
  >> "!B64TMP!" echo IC5lbnYga2V5IC0+IGRlZmF1bHQgcG9ydCAobWF0Y2hlcyB0aGUgZGVmYXVsdHMgaW4gZG9ja2Vy
  >> "!B64TMP!" echo LWNvbXBvc2UueW1sKS4KX1BPUlRfS0VZUyA9IHsKICAgICJzZWFyeG5nIjogKCJTRUFSWE5HX1BP
  >> "!B64TMP!" echo UlQiLCAiOTk5MCIpLAogICAgImZpcmVjcmF3bCI6ICgiRklSRUNSQVdMX1BPUlQiLCAiOTk5MSIp
  >> "!B64TMP!" echo LAp9CgoKZGVmIF9oYXNfY29tcG9zZV9maWxlKGQpOgogICAgcmV0dXJuIGQgaXMgbm90IE5vbmUg
  >> "!B64TMP!" echo YW5kIGFueSgKICAgICAgICBvcy5wYXRoLmlzZmlsZShvcy5wYXRoLmpvaW4oZCwgZikpIGZvciBm
  >> "!B64TMP!" echo IGluIF9DT01QT1NFX0ZJTEVTCiAgICApCgoKRU5HSU5FUyA9ICgicG9kbWFuIiwgImRvY2tlciIp
  >> "!B64TMP!" echo ICAjIHByZWZlcmVuY2Ugb3JkZXI6IFBvZG1hbiB3aW5zIHdoZW4gYm90aCBleGlzdAoKCmRlZiBp
  >> "!B64TMP!" echo bnN0YWxsZWRfZW5naW5lcygpOgogICAgIiIiVGhlIGNvbnRhaW5lciBlbmdpbmVzIGZvdW5kIG9u
  >> "!B64TMP!" echo IFBBVEgsIGluIHByZWZlcmVuY2Ugb3JkZXIuIiIiCiAgICByZXR1cm4gW2UgZm9yIGUgaW4gRU5H
  >> "!B64TMP!" echo SU5FUyBpZiBzaHV0aWwud2hpY2goZSldCgoKZGVmIGVuZ2luZV9jaG9pY2UoaW5zdGFsbF9kaXI9
  >> "!B64TMP!" echo Tm9uZSk6CiAgICAiIiJXaGljaCBjb250YWluZXIgZW5naW5lIHRvIHVzZTogKGVuZ2luZSwgYXV0
  >> "!B64TMP!" echo bykuCgogICAgU2FtZSBydWxlIGFzIGVuZ2luZS5zaCAodGhlIHNoZWxsIHNjcmlwdHMpOgogICAg
  >> "!B64TMP!" echo ICAxLiBMT0NBTF9TRUFSQ0hfRU5HSU5FPXBvZG1hbnxkb2NrZXIgaW4gdGhlIGVudmlyb25tZW50
  >> "!B64TMP!" echo IChmb3JjZWQpLAogICAgICAyLiBMT0NBTF9TRUFSQ0hfRU5HSU5FIGluIHRoZSBpbnN0YWxsIGZv
  >> "!B64TMP!" echo bGRlcidzIC5lbnYgKHRoZSBpbnN0YWxsZXIKICAgICAgICAgcmVjb3JkcyBpdHMgY2hvaWNlIHRo
  >> "!B64TMP!" echo ZXJlKSwKICAgICAgMy4gYXV0by1kZXRlY3Q6IFBvZG1hbiB3aGVuIGluc3RhbGxlZCwgb3RoZXJ3
  >> "!B64TMP!" echo aXNlIERvY2tlci4KICAgIGBlbmdpbmVgIGlzICdwb2RtYW4nLCAnZG9ja2VyJyBvciBOb25lIChu
  >> "!B64TMP!" echo b3RoaW5nIHVzYWJsZSBpbnN0YWxsZWQpOwogICAgYGF1dG9gIGlzIFRydWUgd2hlbiBkZXRlY3Rp
  >> "!B64TMP!" echo b24gcGlja2VkIGl0LCBpLmUuIGEgZmFsbGJhY2sgdG8gdGhlIG90aGVyCiAgICBlbmdpbmUgaXMg
  >> "!B64TMP!" echo YWNjZXB0YWJsZSBpZiB0aGlzIG9uZSBjYW5ub3QgcnVuLgogICAgIiIiCiAgICBmb3JjZWQgPSAo
  >> "!B64TMP!" echo b3MuZW52aXJvbi5nZXQoIkxPQ0FMX1NFQVJDSF9FTkdJTkUiKSBvciAiIikuc3RyaXAoKS5sb3dl
  >> "!B64TMP!" echo cigpCiAgICB3YW50ID0gZm9yY2VkIG9yIGxvYWRfZW52KGluc3RhbGxfZGlyKS5nZXQoIkxPQ0FM
  >> "!B64TMP!" echo X1NFQVJDSF9FTkdJTkUiLCAiIikuc3RyaXAoKS5sb3dlcigpCiAgICBpZiB3YW50IGluIEVOR0lO
  >> "!B64TMP!" echo RVM6CiAgICAgICAgaWYgc2h1dGlsLndoaWNoKHdhbnQpOgogICAgICAgICAgICByZXR1cm4gd2Fu
  >> "!B64TMP!" echo dCwgRmFsc2UKICAgICAgICBpZiBmb3JjZWQ6ICAjIGFuIGV4cGxpY2l0IG92ZXJyaWRlIG11c3Qg
  >> "!B64TMP!" echo bm90IGJlIHNpbGVudGx5IGlnbm9yZWQKICAgICAgICAgICAgcmV0dXJuIE5vbmUsIEZhbHNlCiAg
  >> "!B64TMP!" echo ICBmb3VuZCA9IGluc3RhbGxlZF9lbmdpbmVzKCkKICAgIHJldHVybiAoZm91bmRbMF0gaWYgZm91
  >> "!B64TMP!" echo bmQgZWxzZSBOb25lKSwgVHJ1ZQoKCmRlZiBfbGFiZWxlZF9pbnN0YWxsX2RpcigpOgogICAgIiIi
  >> "!B64TMP!" echo VGhlIGluc3RhbGwgZm9sZGVyIHBlciB0aGUgY29tcG9zZSBsYWJlbCBvbiB0aGUgY29udGFpbmVy
  >> "!B64TMP!" echo cy4gQ29tcG9zZQogICAgdGFncyBlYWNoIGNvbnRhaW5lciB3aXRoIHRoZSBkaXJlY3RvcnkgaXQg
  >> "!B64TMP!" echo d2FzIHN0YXJ0ZWQgZnJvbSwgc28gdGhpcwogICAgZmluZHMgdGhlIGZvbGRlciBldmVuIHRob3Vn
  >> "!B64TMP!" echo aCB0aGUgc2tpbGwgaXRzZWxmIGxpdmVzIGVsc2V3aGVyZS4gQQogICAgY29udGFpbmVyIGVuZ2lu
  >> "!B64TMP!" echo ZSAoUG9kbWFuIG9yIERvY2tlcikgbXVzdCBiZSBydW5uaW5nLiIiIgogICAgZm9yY2VkID0gKG9z
  >> "!B64TMP!" echo LmVudmlyb24uZ2V0KCJMT0NBTF9TRUFSQ0hfRU5HSU5FIikgb3IgIiIpLnN0cmlwKCkubG93ZXIo
  >> "!B64TMP!" echo KQogICAgIyBhbiBleHBsaWNpdCBMT0NBTF9TRUFSQ0hfRU5HSU5FIG1lYW5zICJvbmx5IHRoYXQg
  >> "!B64TMP!" echo ZW5naW5lIgogICAgZm9yIGVuZ2luZSBpbiAoW2ZvcmNlZF0gaWYgZm9yY2VkIGluIEVOR0lORVMg
  >> "!B64TMP!" echo YW5kIHNodXRpbC53aGljaChmb3JjZWQpIGVsc2UgaW5zdGFsbGVkX2VuZ2luZXMoKSk6CiAgICAg
  >> "!B64TMP!" echo ICAgdHJ5OgogICAgICAgICAgICByZXMgPSBzdWJwcm9jZXNzLnJ1bigKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IFtlbmdpbmUsICJjb250YWluZXIiLCAibHMiLCAiLWEiLCAiLXEiLAogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICItLWZpbHRlciIsICJsYWJlbD1jb20uZG9ja2VyLmNvbXBvc2Uuc2VydmljZT1zZWFyeG5nIl0s
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3VicHJvY2Vz
  >> "!B64TMP!" echo cy5ERVZOVUxMLCB0ZXh0PVRydWUpCiAgICAgICAgICAgIGlkcyA9IHJlcy5zdGRvdXQuc3BsaXQo
  >> "!B64TMP!" echo KVs6M10KICAgICAgICBleGNlcHQgKE9TRXJyb3IsIEZpbGVOb3RGb3VuZEVycm9yKToKICAgICAg
  >> "!B64TMP!" echo ICAgICAgY29udGludWUKICAgICAgICBmb3IgY2lkIGluIGlkczoKICAgICAgICAgICAgdHJ5Ogog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgb3V0ID0gc3VicHJvY2Vzcy5ydW4oCiAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo W2VuZ2luZSwgImNvbnRhaW5lciIsICJpbnNwZWN0IiwgY2lkLAogICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiLS1mb3JtYXQiLAogICAgICAgICAgICAgICAgICAgICAne3tpbmRleCAuQ29uZmlnLkxhYmVs
  >> "!B64TMP!" echo cyAiY29tLmRvY2tlci5jb21wb3NlLnByb2plY3Qud29ya2luZ19kaXIifX0nXSwKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZO
  >> "!B64TMP!" echo VUxMLCB0ZXh0PVRydWUpCiAgICAgICAgICAgIGV4Y2VwdCAoT1NFcnJvciwgRmlsZU5vdEZvdW5k
  >> "!B64TMP!" echo RXJyb3IpOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgcCA9IG91dC5zdGRv
  >> "!B64TMP!" echo dXQuc3RyaXAoKQogICAgICAgICAgICBpZiBwIGFuZCBvcy5wYXRoLmlzZGlyKHApOgogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIHAKICAgIHJldHVybiBOb25lCgoKZGVmIF9oaW50ZWRfaW5zdGFsbF9k
  >> "!B64TMP!" echo aXIoKToKICAgICIiIlRoZSBpbnN0YWxsIHBhdGggcmVjb3JkZWQgYnkgdGhlIGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aCBpbnN0YWxsZXIgd2hlbiBpdAogICAgY29waWVkIHRoaXMgc2tpbGwgKGluc3RhbGwtZGlyLnR4
  >> "!B64TMP!" echo dCBuZXh0IHRvIFNLSUxMLm1kKS4gVGhpcyB3b3JrcyBldmVuCiAgICB3aGVuIHRoZSBjb250YWlu
  >> "!B64TMP!" echo ZXIgZW5naW5lIGlzIGRvd24gYW5kIHRoZSBpbnN0YWxsIGZvbGRlciBpcyBub3QgaW4gdGhlCiAg
  >> "!B64TMP!" echo ICBkZWZhdWx0IGxvY2F0aW9uLiBSZXR1cm5zIE5vbmUgd2hlbiB0aGVyZSBpcyBubyBoaW50IGZp
  >> "!B64TMP!" echo bGUgKGUuZy4gdGhlCiAgICBza2lsbCB3YXMgaW5zdGFsbGVkIHN0YW5kYWxvbmUgZnJvbSB0aGUg
  >> "!B64TMP!" echo bG9jYWwtd2ViLXNlYXJjaCByZXBvKS4iIiIKICAgIGhpbnRfZmlsZSA9IG9zLnBhdGguam9pbihv
  >> "!B64TMP!" echo cy5wYXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmlsZV9fKSksCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgb3MucGFyZGlyLCAiaW5zdGFsbC1kaXIudHh0IikKICAgIHRyeToKICAg
  >> "!B64TMP!" echo ICAgICB3aXRoIG9wZW4oaGludF9maWxlLCBlbmNvZGluZz0idXRmLTgiKSBhcyBmaDoKICAgICAg
  >> "!B64TMP!" echo ICAgICAgcGF0aCA9IGZoLnJlYWQoKS5zdHJpcCgpLnJzdHJpcCgiXFwvIikuc3RyaXAoKQogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBwYXRoIG9yIE5vbmUKICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgIHJldHVy
  >> "!B64TMP!" echo biBOb25lCgoKZGVmIGZpbmRfaW5zdGFsbF9kaXIoKToKICAgICIiIlRoZSBsb2NhbC1zZWFyY2gg
  >> "!B64TMP!" echo aW5zdGFsbCBmb2xkZXIgKGhvbGRzIHRoZSBjb21wb3NlIGZpbGUpLCBvciBOb25lLgoKICAgIExv
  >> "!B64TMP!" echo b2tlZCB1cCBpbiBvcmRlcjoKICAgICAgMS4gdGhlIExPQ0FMX1NFQVJDSF9ESVIgZW52IHZhciAo
  >> "!B64TMP!" echo ZXhwbGljaXQgb3ZlcnJpZGUpLAogICAgICAyLiB0aGUgY29tcG9zZSBsYWJlbCBvbiB0aGUgY29u
  >> "!B64TMP!" echo dGFpbmVycyAoYW4gZW5naW5lIG11c3QgYmUgcnVubmluZyksCiAgICAgIDMuIGluc3RhbGwtZGly
  >> "!B64TMP!" echo LnR4dCByZWNvcmRlZCBieSB0aGUgbG9jYWwtc2VhcmNoIGluc3RhbGxlciwKICAgICAgNC4gfi9s
  >> "!B64TMP!" echo b2NhbC1zZWFyY2ggKHRoZSBpbnN0YWxsZXIncyBkZWZhdWx0IGxvY2F0aW9uKS4KICAgICIiIgog
  >> "!B64TMP!" echo ICAgZm9yIGQgaW4gKG9zLmVudmlyb24uZ2V0KCJMT0NBTF9TRUFSQ0hfRElSIiksCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgX2xhYmVsZWRfaW5zdGFsbF9kaXIoKSwKICAgICAgICAgICAgICBfaGludGVkX2luc3Rh
  >> "!B64TMP!" echo bGxfZGlyKCksCiAgICAgICAgICAgICAgb3MucGF0aC5leHBhbmR1c2VyKCJ+L2xvY2FsLXNlYXJj
  >> "!B64TMP!" echo aCIpKToKICAgICAgICBpZiBkIGFuZCBfaGFzX2NvbXBvc2VfZmlsZShkKToKICAgICAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIGQKICAgIHJldHVybiBOb25lCgoKZGVmIGxvYWRfZW52KGluc3RhbGxfZGlyKToKICAg
  >> "!B64TMP!" echo ICIiIlRoZSBpbnN0YWxsIGZvbGRlcidzIC5lbnYgYXMgYSBkaWN0IChlbXB0eSBkaWN0IGlmIG1p
  >> "!B64TMP!" echo c3NpbmcvaW52YWxpZCkuIiIiCiAgICB2YWx1ZXMgPSB7fQogICAgaWYgbm90IGluc3RhbGxfZGly
  >> "!B64TMP!" echo OgogICAgICAgIHJldHVybiB2YWx1ZXMKICAgIHRyeToKICAgICAgICB3aXRoIG9wZW4ob3MucGF0
  >> "!B64TMP!" echo aC5qb2luKGluc3RhbGxfZGlyLCAiLmVudiIpLCBlbmNvZGluZz0idXRmLTgiKSBhcyBmaDoKICAg
  >> "!B64TMP!" echo ICAgICAgICAgZm9yIGxpbmUgaW4gZmg6CiAgICAgICAgICAgICAgICBsaW5lID0gbGluZS5zdHJp
  >> "!B64TMP!" echo cCgpCiAgICAgICAgICAgICAgICBpZiBub3QgbGluZSBvciBsaW5lLnN0YXJ0c3dpdGgoIiMiKSBv
  >> "!B64TMP!" echo ciAiPSIgbm90IGluIGxpbmU6CiAgICAgICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIGtleSwgXywgdmFsID0gbGluZS5wYXJ0aXRpb24oIj0iKQogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo dmFsdWVzW2tleS5zdHJpcCgpXSA9IHZhbC5zdHJpcCgpLnN0cmlwKCciJykuc3RyaXAoIiciKQog
  >> "!B64TMP!" echo ICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgcGFzcwogICAgcmV0dXJuIHZhbHVlcwoKCmRlZiBl
  >> "!B64TMP!" echo bmRwb2ludHMoaW5zdGFsbF9kaXI9Tm9uZSk6CiAgICAiIiJ7J3NlYXJ4bmcnOiAnaHR0cDovL2xv
  >> "!B64TMP!" echo Y2FsaG9zdDo8cG9ydD4nLCAnZmlyZWNyYXdsJzogJy4uLid9LCB3aXRoIHRoZQogICAgcG9ydHMg
  >> "!B64TMP!" echo dGFrZW4gZnJvbSB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52IChkZWZhdWx0cyA5OTkwLzk5OTEp
  >> "!B64TMP!" echo LiIiIgogICAgdmFsdWVzID0gbG9hZF9lbnYoaW5zdGFsbF9kaXIpCiAgICB1cmxzID0ge30KICAg
  >> "!B64TMP!" echo IGZvciBuYW1lLCAoa2V5LCBkZWZhdWx0KSBpbiBfUE9SVF9LRVlTLml0ZW1zKCk6CiAgICAgICAg
  >> "!B64TMP!" echo cG9ydCA9IHZhbHVlcy5nZXQoa2V5KQogICAgICAgIGlmIG5vdCBwb3J0IG9yIG5vdCBwb3J0Lmlz
  >> "!B64TMP!" echo ZGlnaXQoKToKICAgICAgICAgICAgcG9ydCA9IGRlZmF1bHQKICAgICAgICB1cmxzW25hbWVdID0g
  >> "!B64TMP!" echo Imh0dHA6Ly9sb2NhbGhvc3Q6e30iLmZvcm1hdChwb3J0KQogICAgcmV0dXJuIHVybHMK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\config.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/ensure_stack.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\ensure_stack.py" (
  copy /Y "!SRC!\local-web-search\scripts\ensure_stack.py" "!TARGET!\local-web-search\scripts\ensure_stack.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\ensure_stack.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/ensure_stack.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2175738758.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJFbnN1cmUgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBp
  >> "!B64TMP!" echo cyBydW5uaW5nIGJlZm9yZSBhbnkgd2ViIHJlc2VhcmNoLgoKVHdvIHdheXMgdG8gdXNlIGl0OgoK
  >> "!B64TMP!" echo ICAxLiBBcyBhIENMSSBwcmUtZmxpZ2h0IGNoZWNrIChPUFRJT05BTCDigJQgdGhlIG90aGVyIHNj
  >> "!B64TMP!" echo cmlwdHMgc2VsZi1oZWFsKToKICAgICAgICAgcHl0aG9uIGVuc3VyZV9zdGFjay5weSBbLS1jaGVj
  >> "!B64TMP!" echo a10KICAgICBFeGl0IGNvZGVzOiAwIHJlYWR5LCAxIGRvd24gLyBjb3VsZCBub3QgYmUgYnJvdWdo
  >> "!B64TMP!" echo dCB1cCwgMiBwcmVyZXF1aXNpdGVzCiAgICAgbWlzc2luZyAobm8gaW5zdGFsbCBmb2xkZXIsIG5v
  >> "!B64TMP!" echo IFBvZG1hbi9Eb2NrZXIsIG5vIGNvbXBvc2UpLgoKICAyLiBBcyBhIG1vZHVsZSAodXNlZCBieSB3
  >> "!B64TMP!" echo ZWJfc2VhcmNoLnB5IC8gd2ViX3NjcmFwZS5weSBmb3Igc2VsZi1oZWFsaW5nKToKICAgICAgICAg
  >> "!B64TMP!" echo aW1wb3J0IGVuc3VyZV9zdGFjawogICAgICAgICBvaywgbWVzc2FnZSwgY29kZSA9IGVuc3VyZV9z
  >> "!B64TMP!" echo dGFjay5lbnN1cmVfcmVhZHkoKQogICAgIFdoZW4gYSBzZWFyY2gvc2NyYXBlIHJlcXVlc3QgZmFp
  >> "!B64TMP!" echo bHMgd2l0aCBhIGNvbm5lY3Rpb24gZXJyb3IsIHRob3NlCiAgICAgc2NyaXB0cyBjYWxsIGVuc3Vy
  >> "!B64TMP!" echo ZV9yZWFkeSgpIGF1dG9tYXRpY2FsbHksIHRoZW4gcmV0cnkgdGhlIHJlcXVlc3QKICAgICBvbmNl
  >> "!B64TMP!" echo IOKAlCBzbyB0aGUgYWdlbnQgY2FuIGNhbGwgdGhlbSBkaXJlY3RseSB3aXRoIG5vIHdhcm0tdXAg
  >> "!B64TMP!" echo c3RlcC4KCkJlaGF2aW91ciAoYm90aCBDTEkgYW5kIG1vZHVsZSk6CiAgKiBCb3RoIGVuZHBvaW50
  >> "!B64TMP!" echo cyBhbnN3ZXJpbmcgLT4gcmV0dXJuIGltbWVkaWF0ZWx5IChmYXN0IHBhdGgsIDwgMSBzKS4KICAq
  >> "!B64TMP!" echo IE90aGVyd2lzZTogbWFrZSBzdXJlIHRoZSBjb250YWluZXIgZW5naW5lIGlzIHJ1bm5pbmcgKGlm
  >> "!B64TMP!" echo IGl0IGlzIGRvd24sIGxhdW5jaAogICAgRG9ja2VyIERlc2t0b3AgLyB0aGUgZG9ja2VyIHNlcnZp
  >> "!B64TMP!" echo Y2UgLyB0aGUgUG9kbWFuIG1hY2hpbmUgYW5kIHdhaXQgZm9yIGl0KSwKICAgIHRoZW4gc3RhcnQg
  >> "!B64TMP!" echo dGhlIGNvbnRhaW5lcnMgd2l0aCBgcG9kbWFuIGNvbXBvc2UgdXAgLWRgIC8gYGRvY2tlciBjb21w
  >> "!B64TMP!" echo b3NlCiAgICB1cCAtZGAgaW4gdGhlIGluc3RhbGwgZm9sZGVyICh0aGUgc2FtZSBjb21tYW5kIFJ1
  >> "!B64TMP!" echo bi5iYXQgLyBydW4uc2ggcnVuLAogICAgd2l0aG91dCB0aGUgaW50ZXJhY3RpdmUgYHBhdXNlYCkg
  >> "!B64TMP!" echo YW5kIHdhaXQgdW50aWwgYm90aCBlbmRwb2ludHMgYW5zd2VyLgogICAgVGhlIGVuZ2luZSBpcyBQ
  >> "!B64TMP!" echo b2RtYW4gd2hlbiBpdCBpcyBpbnN0YWxsZWQgKGl0IHdpbnMgd2hlbiBib3RoIGFyZSksIGVsc2UK
  >> "!B64TMP!" echo ICAgIERvY2tlciAtIG92ZXJyaWRlIHdpdGggTE9DQUxfU0VBUkNIX0VOR0lORT1wb2RtYW58ZG9j
  >> "!B64TMP!" echo a2VyLCBvciB0aGUgc2FtZSBsaW5lCiAgICBpbiB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52ICh0
  >> "!B64TMP!" echo aGUgaW5zdGFsbGVyIHJlY29yZHMgaXRzIGNob2ljZSB0aGVyZSkuCiAgICBUaGUgc3RhY2sgaXMg
  >> "!B64TMP!" echo TkVWRVIgc3RvcHBlZCBieSB0aGlzIHNjcmlwdC4KClRoZSByZWFkaW5lc3MgdGltZW91dCBkZWZh
  >> "!B64TMP!" echo dWx0cyB0byAyNDAgcyBhbmQgY2FuIGJlIG92ZXJyaWRkZW4gd2l0aCB0aGUKTE9DQUxfU0VBUkNI
  >> "!B64TMP!" echo X1JFQURZX1RJTUVPVVQgZW52IHZhciAoc2Vjb25kcykg4oCUIHVzZWQgYnkgdGhlIHRlc3Qgc3Vp
  >> "!B64TMP!" echo dGUgdG8KZXhlcmNpc2UgdGhlIGZhaWx1cmUgcGF0aCBxdWlja2x5LgoKVGhlIGluc3RhbGwgZm9s
  >> "!B64TMP!" echo ZGVyIChob2xkcyBkb2NrZXItY29tcG9zZS55bWwpIGlzIGZvdW5kIGJ5IGNvbmZpZy5weSwgaW4g
  >> "!B64TMP!" echo b3JkZXI6CiAgICAxLiB0aGUgTE9DQUxfU0VBUkNIX0RJUiBlbnYgdmFyIChleHBsaWNpdCBvdmVy
  >> "!B64TMP!" echo cmlkZSksCiAgICAyLiB0aGUgY29tcG9zZSBsYWJlbCBvbiB0aGUgY29udGFpbmVycyDigJQgY29t
  >> "!B64TMP!" echo cG9zZSB0YWdzIGVhY2ggY29udGFpbmVyIHdpdGgKICAgICAgIHRoZSBkaXJlY3RvcnkgaXQgd2Fz
  >> "!B64TMP!" echo IHN0YXJ0ZWQgZnJvbSAoZW5naW5lIG11c3QgYmUgdXApLAogICAgMy4gaW5zdGFsbC1kaXIudHh0
  >> "!B64TMP!" echo IOKAlCB0aGUgcGF0aCByZWNvcmRlZCBieSB0aGUgbG9jYWwtc2VhcmNoIGluc3RhbGxlcgogICAg
  >> "!B64TMP!" echo ICAgd2hlbiBpdCBjb3BpZWQgdGhpcyBza2lsbCwKICAgIDQuIH4vbG9jYWwtc2VhcmNoLgoiIiIK
  >> "!B64TMP!" echo aW1wb3J0IGFyZ3BhcnNlCmltcG9ydCBvcwppbXBvcnQgc2h1dGlsCmltcG9ydCBzdWJwcm9jZXNz
  >> "!B64TMP!" echo CmltcG9ydCBzeXMKaW1wb3J0IHRpbWUKaW1wb3J0IHVybGxpYi5lcnJvcgppbXBvcnQgdXJsbGli
  >> "!B64TMP!" echo LnJlcXVlc3QKCiMgRGVmYXVsdCBzdGRvdXQvc3RkZXJyIHRvIFVURi04IHJlZ2FyZGxlc3Mgb2Yg
  >> "!B64TMP!" echo dGhlIGhvc3QgbG9jYWxlL2NvZGVwYWdlCiMgKGUuZy4gV2luZG93cyBjcDEyNTIpLCBzbyBzdGF0
  >> "!B64TMP!" echo dXMvcHJvZ3Jlc3MgbWVzc2FnZXMgbmV2ZXIgY3Jhc2ggd2l0aCBhCiMgVW5pY29kZUVuY29kZUVy
  >> "!B64TMP!" echo cm9yLiBTa2lwcGVkIGlmIFBZVEhPTklPRU5DT0RJTkcgaXMgYWxyZWFkeSBzZXQg4oCUIGFuCiMg
  >> "!B64TMP!" echo ZXhwbGljaXQgb3ZlcnJpZGUgYWx3YXlzIHdpbnMuCmlmICJQWVRIT05JT0VOQ09ESU5HIiBub3Qg
  >> "!B64TMP!" echo aW4gb3MuZW52aXJvbjoKICAgIGZvciBfc3RyZWFtIGluIChzeXMuc3Rkb3V0LCBzeXMuc3RkZXJy
  >> "!B64TMP!" echo KToKICAgICAgICBpZiBoYXNhdHRyKF9zdHJlYW0sICJyZWNvbmZpZ3VyZSIpOgogICAgICAgICAg
  >> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgICAgICAgICBfc3RyZWFtLnJlY29uZmlndXJlKGVuY29kaW5nPSJ1dGYt
  >> "!B64TMP!" echo OCIpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICBwYXNzCgpz
  >> "!B64TMP!" echo eXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVf
  >> "!B64TMP!" echo XykpKQppbXBvcnQgY29uZmlnICAjIHNpYmxpbmcgbW9kdWxlOiBpbnN0YWxsLWRpciBsb29rdXAg
  >> "!B64TMP!" echo KyAuZW52LWRyaXZlbiBlbmRwb2ludHMKClJFQURZX1RJTUVPVVQgPSBpbnQob3MuZW52aXJvbi5n
  >> "!B64TMP!" echo ZXQoIkxPQ0FMX1NFQVJDSF9SRUFEWV9USU1FT1VUIiwgIjI0MCIpIG9yIDI0MCkKUE9MTF9FVkVS
  >> "!B64TMP!" echo WSA9IDMKRElTUExBWSA9IHsic2VhcnhuZyI6ICJTZWFyWE5HIiwgImZpcmVjcmF3bCI6ICJGaXJl
  >> "!B64TMP!" echo Y3Jhd2wifQoKCmRlZiBlbmRwb2ludF91cCh1cmwsIHRpbWVvdXQ9NCk6CiAgICAiIiJUcnVlIGlm
  >> "!B64TMP!" echo IHRoZSBlbmRwb2ludCBhY2NlcHRzIGNvbm5lY3Rpb25zIChhbnkgSFRUUCBzdGF0dXMgY291bnRz
  >> "!B64TMP!" echo KS4iIiIKICAgIHJlcSA9IHVybGxpYi5yZXF1ZXN0LlJlcXVlc3QodXJsKQogICAgdHJ5OgogICAg
  >> "!B64TMP!" echo ICAgIHdpdGggdXJsbGliLnJlcXVlc3QudXJsb3BlbihyZXEsIHRpbWVvdXQ9dGltZW91dCk6CiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHJldHVybiBUcnVlCiAgICBleGNlcHQgdXJsbGliLmVycm9yLkhUVFBFcnJvcjoK
  >> "!B64TMP!" echo ICAgICAgICByZXR1cm4gVHJ1ZSAgIyBnb3QgYW4gSFRUUCByZXNwb25zZSAoZXZlbiA0eHgvNXh4
  >> "!B64TMP!" echo KSA9IHNlcnZpY2UgaXMgdXAKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcmV0dXJuIEZh
  >> "!B64TMP!" echo bHNlICAjIGNvbm5lY3Rpb24gcmVmdXNlZCAvIHJlc2V0IC8gdGltZW91dCA9IGRvd24KCgpkZWYg
  >> "!B64TMP!" echo cG9ydF9vZih1cmwpOgogICAgcmV0dXJuIHVybC5yc3BsaXQoIjoiLCAxKVsxXQoKCmRlZiBzdGF0
  >> "!B64TMP!" echo dXMoZW5kcG9pbnRzKToKICAgIHJldHVybiB7bmFtZTogZW5kcG9pbnRfdXAodXJsKSBmb3IgbmFt
  >> "!B64TMP!" echo ZSwgdXJsIGluIGVuZHBvaW50cy5pdGVtcygpfQoKCmRlZiByZWFkeV9tZXNzYWdlKGVuZHBvaW50
  >> "!B64TMP!" echo cyk6CiAgICByZXR1cm4gIlN0YWNrIGlzIHJlYWR5IChTZWFyWE5HIDp7MH0sIEZpcmVjcmF3bCA6
  >> "!B64TMP!" echo ezF9KS4iLmZvcm1hdCgKICAgICAgICBwb3J0X29mKGVuZHBvaW50c1sic2VhcnhuZyJdKSwgcG9y
  >> "!B64TMP!" echo dF9vZihlbmRwb2ludHNbImZpcmVjcmF3bCJdKSkKCgpkZWYgX29rKGNtZCk6CiAgICB0cnk6CiAg
  >> "!B64TMP!" echo ICAgICAgcmV0dXJuIHN1YnByb2Nlc3MucnVuKGNtZCwgc3Rkb3V0PXN1YnByb2Nlc3MuREVWTlVM
  >> "!B64TMP!" echo TCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVM
  >> "!B64TMP!" echo TCkucmV0dXJuY29kZSA9PSAwCiAgICBleGNlcHQgKE9TRXJyb3IsIEZpbGVOb3RGb3VuZEVycm9y
  >> "!B64TMP!" echo KToKICAgICAgICByZXR1cm4gRmFsc2UKCgpkZWYgY29tcG9zZV9jb21tYW5kKGVuZ2luZT0iZG9j
  >> "!B64TMP!" echo a2VyIik6CiAgICBpZiBlbmdpbmUgPT0gInBvZG1hbiI6CiAgICAgICAgaWYgc2h1dGlsLndoaWNo
  >> "!B64TMP!" echo KCJwb2RtYW4iKSBhbmQgX29rKFsicG9kbWFuIiwgImNvbXBvc2UiLCAidmVyc2lvbiJdKToKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIFsicG9kbWFuIiwgImNvbXBvc2UiXQogICAgICAgIGlmIHNodXRpbC53
  >> "!B64TMP!" echo aGljaCgicG9kbWFuLWNvbXBvc2UiKToKICAgICAgICAgICAgcmV0dXJuIFsicG9kbWFuLWNvbXBv
  >> "!B64TMP!" echo c2UiXQogICAgICAgIHJldHVybiBOb25lCiAgICBpZiBzaHV0aWwud2hpY2goImRvY2tlciIpIGFu
  >> "!B64TMP!" echo ZCBfb2soWyJkb2NrZXIiLCAiY29tcG9zZSIsICJ2ZXJzaW9uIl0pOgogICAgICAgIHJldHVybiBb
  >> "!B64TMP!" echo ImRvY2tlciIsICJjb21wb3NlIl0KICAgIGlmIHNodXRpbC53aGljaCgiZG9ja2VyLWNvbXBvc2Ui
  >> "!B64TMP!" echo KToKICAgICAgICByZXR1cm4gWyJkb2NrZXItY29tcG9zZSJdCiAgICByZXR1cm4gTm9uZQoKCmRl
  >> "!B64TMP!" echo ZiBlbmdpbmVfdXAoZW5naW5lKToKICAgIHJldHVybiBfb2soW2VuZ2luZSwgImluZm8iXSkKCgpk
  >> "!B64TMP!" echo ZWYgZW5zdXJlX3BvZG1hbl9zb2NrZXQoKToKICAgICIiImBwb2RtYW4gY29tcG9zZWAgbm9ybWFs
  >> "!B64TMP!" echo bHkgaGFuZHMgb3ZlciB0byBkb2NrZXItY29tcG9zZSwgd2hpY2ggdGFsa3MgdG8KICAgIFBvZG1h
  >> "!B64TMP!" echo bidzIEFQSSBzb2NrZXQ7IG9uIGEgZnJlc2ggRmVkb3JhIHNlc3Npb24gdGhhdCBzb2NrZXQgaXMg
  >> "!B64TMP!" echo bm90IHJ1bm5pbmcuCiAgICBCZXN0IGVmZm9ydCwgTGludXggb25seSwgbmV2ZXIgZmF0YWwuIFRy
  >> "!B64TMP!" echo dWUgd2hlbiB0aGUgc29ja2V0IGV4aXN0cy4iIiIKICAgIGltcG9ydCBwbGF0Zm9ybQogICAgaWYg
  >> "!B64TMP!" echo cGxhdGZvcm0uc3lzdGVtKCkgIT0gIkxpbnV4IjoKICAgICAgICByZXR1cm4gVHJ1ZQoKICAgIGRl
  >> "!B64TMP!" echo ZiBleGlzdHMoKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIG91dCA9IHN1YnByb2Nlc3MucnVu
  >> "!B64TMP!" echo KAogICAgICAgICAgICAgICAgWyJwb2RtYW4iLCAiaW5mbyIsICItLWZvcm1hdCIsICJ7ey5Ib3N0
  >> "!B64TMP!" echo LlJlbW90ZVNvY2tldC5FeGlzdHN9fSJdLAogICAgICAgICAgICAgICAgc3Rkb3V0PXN1YnByb2Nl
  >> "!B64TMP!" echo c3MuUElQRSwgc3RkZXJyPXN1YnByb2Nlc3MuREVWTlVMTCwgdGV4dD1UcnVlKQogICAgICAgICAg
  >> "!B64TMP!" echo ICByZXR1cm4gb3V0LnN0ZG91dC5zdHJpcCgpID09ICJ0cnVlIgogICAgICAgIGV4Y2VwdCAoT1NF
  >> "!B64TMP!" echo cnJvciwgRmlsZU5vdEZvdW5kRXJyb3IpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKCiAgICBp
  >> "!B64TMP!" echo ZiBleGlzdHMoKToKICAgICAgICByZXR1cm4gVHJ1ZQogICAgaWYgc2h1dGlsLndoaWNoKCJzeXN0
  >> "!B64TMP!" echo ZW1jdGwiKToKICAgICAgICByb290bGVzcyA9IHN1YnByb2Nlc3MucnVuKAogICAgICAgICAgICBb
  >> "!B64TMP!" echo InBvZG1hbiIsICJpbmZvIiwgIi0tZm9ybWF0IiwgInt7Lkhvc3QuU2VjdXJpdHkuUm9vdGxlc3N9
  >> "!B64TMP!" echo fSJdLAogICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLCBzdGRlcnI9c3VicHJvY2Vz
  >> "!B64TMP!" echo cy5ERVZOVUxMLCB0ZXh0PVRydWUKICAgICAgICApLnN0ZG91dC5zdHJpcCgpID09ICJ0cnVlIgog
  >> "!B64TMP!" echo ICAgICAgIGlmIHJvb3RsZXNzOgogICAgICAgICAgICBfb2soWyJzeXN0ZW1jdGwiLCAiLS11c2Vy
  >> "!B64TMP!" echo IiwgInN0YXJ0IiwgInBvZG1hbi5zb2NrZXQiXSkKICAgICAgICBlbGlmIG5vdCBfb2soWyJzeXN0
  >> "!B64TMP!" echo ZW1jdGwiLCAic3RhcnQiLCAicG9kbWFuLnNvY2tldCJdKSBhbmQgc2h1dGlsLndoaWNoKCJzdWRv
  >> "!B64TMP!" echo Iik6CiAgICAgICAgICAgIF9vayhbInN1ZG8iLCAiLW4iLCAic3lzdGVtY3RsIiwgInN0YXJ0Iiwg
  >> "!B64TMP!" echo InBvZG1hbi5zb2NrZXQiXSkKICAgIHJldHVybiBleGlzdHMoKQoKCmRlZiBmaW5kX2RvY2tlcl9k
  >> "!B64TMP!" echo ZXNrdG9wX2V4ZSgpOgogICAgY2FuZGlkYXRlcyA9IFsKICAgICAgICByIkM6XFByb2dyYW0gRmls
  >> "!B64TMP!" echo ZXNcRG9ja2VyXERvY2tlclxEb2NrZXIgRGVza3RvcC5leGUiLAogICAgICAgIG9zLnBhdGguZXhw
  >> "!B64TMP!" echo YW5kdmFycyhyIiVMT0NBTEFQUERBVEElXFByb2dyYW1zXERvY2tlciBEZXNrdG9wXERvY2tlciBE
  >> "!B64TMP!" echo ZXNrdG9wLmV4ZSIpLAogICAgXQogICAgZm9yIHAgaW4gY2FuZGlkYXRlczoKICAgICAgICBpZiBv
  >> "!B64TMP!" echo cy5wYXRoLmlzZmlsZShwKToKICAgICAgICAgICAgcmV0dXJuIHAKICAgIHJldHVybiBOb25lCgoK
  >> "!B64TMP!" echo ZGVmIHN0YXJ0X2VuZ2luZShlbmdpbmUpOgogICAgIiIiVHJ5IHRvIGxhdW5jaCB0aGUgY29udGFp
  >> "!B64TMP!" echo bmVyIGVuZ2luZSBmb3IgdGhpcyBPUy4gVHJ1ZSBpZiB0aGUgbGF1bmNoIHdhcwogICAgaW5pdGlh
  >> "!B64TMP!" echo dGVkIChub3QgdGhhdCBpdCBiZWNhbWUgcmVhZHkg4oCUIHRoYXQncyB3YWl0X2Zvcl9lbmdpbmUn
  >> "!B64TMP!" echo cyBqb2IpLiIiIgogICAgaW1wb3J0IHBsYXRmb3JtCiAgICBzeXN0ZW0gPSBwbGF0Zm9ybS5zeXN0
  >> "!B64TMP!" echo ZW0oKQogICAgaWYgZW5naW5lID09ICJwb2RtYW4iOgogICAgICAgICMgTGludXg6IHJvb3RsZXNz
  >> "!B64TMP!" echo IFBvZG1hbiBoYXMgbm8gZGFlbW9uIC0gbm90aGluZyB0byBzdGFydC4gbWFjT1MgLwogICAgICAg
  >> "!B64TMP!" echo ICMgV2luZG93czogUG9kbWFuIHJ1bnMgaW4gYSBWTSAoInBvZG1hbiBtYWNoaW5lIikgdGhhdCBt
  >> "!B64TMP!" echo dXN0IGJlIHN0YXJ0ZWQuCiAgICAgICAgaWYgc3lzdGVtID09ICJMaW51eCI6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IHJldHVybiBGYWxzZQogICAgICAgIHRyeToKICAgICAgICAgICAgbmFtZXMgPSBzdWJwcm9jZXNz
  >> "!B64TMP!" echo LnJ1bigKICAgICAgICAgICAgICAgIFsicG9kbWFuIiwgIm1hY2hpbmUiLCAibGlzdCIsICItLWZv
  >> "!B64TMP!" echo cm1hdCIsICJ7ey5OYW1lfX0iXSwKICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLlBJ
  >> "!B64TMP!" echo UEUsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwsIHRleHQ9VHJ1ZSkKICAgICAgICAgICAgaWYg
  >> "!B64TMP!" echo bm90IG5hbWVzLnN0ZG91dC5zdHJpcCgpOgogICAgICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHN1YnByb2Nlc3MuUG9wZW4oWyJwb2RtYW4iLCAibWFjaGluZSIsICJzdGFydCJd
  >> "!B64TMP!" echo LAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEws
  >> "!B64TMP!" echo IHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwpCiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAg
  >> "!B64TMP!" echo ICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgc3lzdGVt
  >> "!B64TMP!" echo ID09ICJXaW5kb3dzIjoKICAgICAgICBleGUgPSBmaW5kX2RvY2tlcl9kZXNrdG9wX2V4ZSgpCiAg
  >> "!B64TMP!" echo ICAgICAgaWYgbm90IGV4ZToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgdHJ5Ogog
  >> "!B64TMP!" echo ICAgICAgICAgICBzdWJwcm9jZXNzLlBvcGVuKFtleGVdLAogICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5V
  >> "!B64TMP!" echo TEwpCiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgc3lzdGVtID09ICJEYXJ3aW4iOgogICAgICAgIHRy
  >> "!B64TMP!" echo eToKICAgICAgICAgICAgc3VicHJvY2Vzcy5Qb3BlbihbIm9wZW4iLCAiLS1iYWNrZ3JvdW5kIiwg
  >> "!B64TMP!" echo Ii1hIiwgIkRvY2tlciJdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJw
  >> "!B64TMP!" echo cm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwpCiAgICAgICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiBUcnVlCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIHJldHVybiBGYWxz
  >> "!B64TMP!" echo ZQogICAgIyBMaW51eDogYmVzdCBlZmZvcnQgd2l0aG91dCBhbiBpbnRlcmFjdGl2ZSBwYXNzd29y
  >> "!B64TMP!" echo ZCBwcm9tcHQuCiAgICB0cnk6CiAgICAgICAgaWYgaGFzYXR0cihvcywgImdldGV1aWQiKSBhbmQg
  >> "!B64TMP!" echo b3MuZ2V0ZXVpZCgpID09IDA6CiAgICAgICAgICAgIHJldHVybiBzdWJwcm9jZXNzLnJ1bihbInN5
  >> "!B64TMP!" echo c3RlbWN0bCIsICJzdGFydCIsICJkb2NrZXIiXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsCiAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMKS5yZXR1cm5jb2RlID09IDAKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gc3VicHJvY2Vzcy5ydW4oWyJzdWRvIiwgIi1uIiwgInN5c3RlbWN0bCIsICJz
  >> "!B64TMP!" echo dGFydCIsICJkb2NrZXIiXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3Rkb3V0PXN1
  >> "!B64TMP!" echo YnByb2Nlc3MuREVWTlVMTCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgc3RkZXJyPXN1
  >> "!B64TMP!" echo YnByb2Nlc3MuREVWTlVMTCkucmV0dXJuY29kZSA9PSAwCiAgICBleGNlcHQgKE9TRXJyb3IsIEZp
  >> "!B64TMP!" echo bGVOb3RGb3VuZEVycm9yKToKICAgICAgICByZXR1cm4gRmFsc2UKCgpkZWYgd2FpdF9mb3JfZW5n
  >> "!B64TMP!" echo aW5lKGVuZ2luZSwgdGltZW91dD0xODApOgogICAgZGVhZGxpbmUgPSB0aW1lLnRpbWUoKSArIHRp
  >> "!B64TMP!" echo bWVvdXQKICAgIHdoaWxlIHRpbWUudGltZSgpIDwgZGVhZGxpbmU6CiAgICAgICAgaWYgZW5naW5l
  >> "!B64TMP!" echo X3VwKGVuZ2luZSk6CiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgdGltZS5zbGVlcCgz
  >> "!B64TMP!" echo KQogICAgcmV0dXJuIEZhbHNlCgoKZGVmIGVuc3VyZV9yZWFkeShjaGVja19vbmx5PUZhbHNlLCBy
  >> "!B64TMP!" echo ZWFkeV90aW1lb3V0PU5vbmUsIHBvbGxfZXZlcnk9Tm9uZSk6CiAgICAiIiJCcmluZyB0aGUgbG9j
  >> "!B64TMP!" echo YWwtc2VhcmNoIHN0YWNrIHRvIGEgcmVhZHkgc3RhdGUuIE5FVkVSIHN0b3BzIGl0LgoKICAgIFJl
  >> "!B64TMP!" echo dHVybnMgKG9rLCBtZXNzYWdlLCBleGl0X2NvZGUpOgogICAgICAgIG9rICAgICAgICAgVHJ1ZSB3
  >> "!B64TMP!" echo aGVuIGJvdGggZW5kcG9pbnRzIGFuc3dlci4KICAgICAgICBtZXNzYWdlICAgIGh1bWFuLXJlYWRh
  >> "!B64TMP!" echo YmxlIHN0YXR1cyAvIGd1aWRhbmNlIChwcm9ncmVzcyBpcyBwcmludGVkIHRvCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBzdGRlcnIgYWxvbmcgdGhlIHdheSkuCiAgICAgICAgZXhpdF9jb2RlICAwIHJlYWR5
  >> "!B64TMP!" echo LCAxIGRvd24vY291bGQgbm90IGJyaW5nIHVwLCAyIHByZXJlcXVpc2l0ZXMKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIG1pc3NpbmcgKG1hdGNoZXMgdGhlIENMSSBleGl0IGNvZGVzKS4KICAgICIiIgogICAg
  >> "!B64TMP!" echo aWYgcmVhZHlfdGltZW91dCBpcyBOb25lOgogICAgICAgIHJlYWR5X3RpbWVvdXQgPSBSRUFEWV9U
  >> "!B64TMP!" echo SU1FT1VUCiAgICBpZiBwb2xsX2V2ZXJ5IGlzIE5vbmU6CiAgICAgICAgcG9sbF9ldmVyeSA9IFBP
  >> "!B64TMP!" echo TExfRVZFUlkKCiAgICBlbmRwb2ludHMgPSBjb25maWcuZW5kcG9pbnRzKGNvbmZpZy5maW5kX2lu
  >> "!B64TMP!" echo c3RhbGxfZGlyKCkpCiAgICBzdCA9IHN0YXR1cyhlbmRwb2ludHMpCiAgICBpZiBhbGwoc3QudmFs
  >> "!B64TMP!" echo dWVzKCkpOgogICAgICAgIHJldHVybiBUcnVlLCByZWFkeV9tZXNzYWdlKGVuZHBvaW50cyksIDAK
  >> "!B64TMP!" echo CiAgICBwcmludCgiTG9jYWwtc2VhcmNoIHN0YWNrIGlzIERPV046IiwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgZm9yIG5hbWUsIHVybCBpbiBlbmRwb2ludHMuaXRlbXMoKToKICAgICAgICBtYXJrID0g
  >> "!B64TMP!" echo Ik9LICAiIGlmIHN0W25hbWVdIGVsc2UgIkRPV04iCiAgICAgICAgcHJpbnQoZiIgIFt7bWFya31d
  >> "!B64TMP!" echo IHtESVNQTEFZW25hbWVdfSA6e3BvcnRfb2YodXJsKX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICBp
  >> "!B64TMP!" echo ZiBjaGVja19vbmx5OgogICAgICAgIHJldHVybiBGYWxzZSwgIlN0YWNrIGlzIGRvd24gKC0tY2hl
  >> "!B64TMP!" echo Y2s6IG5vdGhpbmcgd2FzIHN0YXJ0ZWQpLiIsIDEKCiAgICBlbmdpbmUsIGF1dG8gPSBjb25maWcu
  >> "!B64TMP!" echo ZW5naW5lX2Nob2ljZShjb25maWcuZmluZF9pbnN0YWxsX2RpcigpKQogICAgaWYgZW5naW5lIGlz
  >> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgcmV0dXJuIEZhbHNlLCAoIk5vIGNvbnRhaW5lciBlbmdpbmUgZm91bmQ6
  >> "!B64TMP!" echo IG5laXRoZXIgUG9kbWFuIG5vciBEb2NrZXIgaXMgIgogICAgICAgICAgICAgICAgICAgICAgICJv
  >> "!B64TMP!" echo biBQQVRIIChvciBMT0NBTF9TRUFSQ0hfRU5HSU5FIG5hbWVzIG9uZSB0aGF0IGlzIG5vdCAiCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgImluc3RhbGxlZCkuIEluc3RhbGwgb25lLCB0aGVuIHJlLXJ1
  >> "!B64TMP!" echo biB0aGlzIHNjcmlwdC4iKSwgMgogICAgbmFtZSA9IGVuZ2luZS5jYXBpdGFsaXplKCkKCiAgICBp
  >> "!B64TMP!" echo ZiBub3QgZW5naW5lX3VwKGVuZ2luZSk6CiAgICAgICAgcHJpbnQoZiJ7bmFtZX0gZW5naW5lIGlz
  >> "!B64TMP!" echo IG5vdCBydW5uaW5nIOKAlCB0cnlpbmcgdG8gc3RhcnQgaXQgLi4uIiwKICAgICAgICAgICAgICBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgc3RhcnRfZW5naW5lKGVuZ2luZSk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIHByaW50KGYiV2FpdGluZyBmb3IgdGhlIHtuYW1lfSBlbmdpbmUgdG8gY29tZSB1cCAuLi4i
  >> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIGlmIG5vdCB3YWl0X2Zvcl9lbmdpbmUoZW5n
  >> "!B64TMP!" echo aW5lLCB0aW1lb3V0PTE4MCk6CiAgICAgICAgICAgICAgICByZXR1cm4gRmFsc2UsIChmIlRoZSB7
  >> "!B64TMP!" echo bmFtZX0gZW5naW5lIHdhcyBsYXVuY2hlZCBidXQgZGlkIG5vdCBhbnN3ZXIgIgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgZiJ3aXRoaW4gMTgwIHMuIENoZWNrIHtuYW1lfSwgdGhlbiBy
  >> "!B64TMP!" echo ZS1ydW4gdGhpcyBzY3JpcHQuIiksIDIKICAgICAgICBlbGlmIGF1dG8gYW5kIGVuZ2luZSA9PSAi
  >> "!B64TMP!" echo cG9kbWFuIiBhbmQgc2h1dGlsLndoaWNoKCJkb2NrZXIiKSBhbmQgZW5naW5lX3VwKCJkb2NrZXIi
  >> "!B64TMP!" echo KToKICAgICAgICAgICAgcHJpbnQoIlBvZG1hbiBpcyBub3QgcmVzcG9uZGluZyDigJQgdXNpbmcg
  >> "!B64TMP!" echo RG9ja2VyIGluc3RlYWQuIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBlbmdpbmUsIG5h
  >> "!B64TMP!" echo bWUgPSAiZG9ja2VyIiwgIkRvY2tlciIKICAgICAgICBlbHNlOgogICAgICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo RmFsc2UsIChmIkNvdWxkIG5vdCBzdGFydCB0aGUge25hbWV9IGVuZ2luZSBhdXRvbWF0aWNhbGx5
  >> "!B64TMP!" echo ICIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIihEb2NrZXIgRGVza3RvcCBub3QgZm91bmQg
  >> "!B64TMP!" echo aW4gdGhlIHVzdWFsIGxvY2F0aW9ucz8gIgogICAgICAgICAgICAgICAgICAgICAgICAgICAiSXMg
  >> "!B64TMP!" echo cm9vdGxlc3MgUG9kbWFuIHNldCB1cCDigJQgZG9lcyAncG9kbWFuIGluZm8nIHdvcms/KS4gIgog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAiU3RhcnQgaXQgbWFudWFsbHksIHRoZW4gcmUtcnVu
  >> "!B64TMP!" echo IHRoaXMgc2NyaXB0LiIpLCAyCgogICAgIyBSZWNvbXB1dGVkIG5vdyB0aGF0IHRoZSBlbmdpbmUg
  >> "!B64TMP!" echo aXMgdXA6IHRoZSBjb21wb3NlLWxhYmVsIGxvb2t1cCAod2hpY2gKICAgICMgbmVlZHMgdGhlIGVu
  >> "!B64TMP!" echo Z2luZSkgY2FuIGZpbmQgdGhlIGluc3RhbGwgZGlyIHdoZXJlIHRoZSBvdGhlciBtZXRob2RzCiAg
  >> "!B64TMP!" echo ICAjIGNvdWxkIG5vdC4KICAgIGluc3RhbGxfZGlyID0gY29uZmlnLmZpbmRfaW5zdGFsbF9kaXIo
  >> "!B64TMP!" echo KQogICAgaWYgbm90IGluc3RhbGxfZGlyOgogICAgICAgIHJldHVybiBGYWxzZSwgKCJDb3VsZCBu
  >> "!B64TMP!" echo b3QgZmluZCB0aGUgbG9jYWwtc2VhcmNoIGluc3RhbGwgZm9sZGVyICIKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAiKG5vIGRvY2tlci1jb21wb3NlLnltbCBmb3VuZCkuIEFzayB0aGUgdXNlciB3aGVy
  >> "!B64TMP!" echo ZSB0aGVpciAiCiAgICAgICAgICAgICAgICAgICAgICAgImxvY2FsLXNlYXJjaCBmb2xkZXIgaXMs
  >> "!B64TMP!" echo IHRoZW4gcmUtcnVuIHRoaXMgc2NyaXB0IHdpdGggIgogICAgICAgICAgICAgICAgICAgICAgICJM
  >> "!B64TMP!" echo T0NBTF9TRUFSQ0hfRElSIHNldCB0byB0aGF0IHBhdGgsIG9yIHN0YXJ0IHRoZSBzdGFjayBtYW51
  >> "!B64TMP!" echo YWxseSAiCiAgICAgICAgICAgICAgICAgICAgICAgIihSdW4uYmF0IC8gcnVuLnNoKS4iKSwgMgoK
  >> "!B64TMP!" echo ICAgIGNvbXBvc2UgPSBjb21wb3NlX2NvbW1hbmQoZW5naW5lKQogICAgaWYgbm90IGNvbXBvc2U6
  >> "!B64TMP!" echo CiAgICAgICAgaWYgZW5naW5lID09ICJwb2RtYW4iOgogICAgICAgICAgICByZXR1cm4gRmFsc2Us
  >> "!B64TMP!" echo ICgiTm8gY29tcG9zZSBwcm92aWRlciBmb3IgUG9kbWFuOiBpbnN0YWxsICdkb2NrZXItY29tcG9z
  >> "!B64TMP!" echo ZScgIgogICAgICAgICAgICAgICAgICAgICAgICAgICAiKENvbXBvc2UgdjIpIG9yICdwb2RtYW4t
  >> "!B64TMP!" echo Y29tcG9zZScuIiksIDIKICAgICAgICByZXR1cm4gRmFsc2UsICJOZWl0aGVyICdkb2NrZXIgY29t
  >> "!B64TMP!" echo cG9zZScgbm9yICdkb2NrZXItY29tcG9zZScgaXMgYXZhaWxhYmxlLiIsIDIKICAgIGNvbXBvc2Vf
  >> "!B64TMP!" echo bGFiZWwgPSAiICIuam9pbihjb21wb3NlKQoKICAgIGVudiA9IGRpY3Qob3MuZW52aXJvbikKICAg
  >> "!B64TMP!" echo IGlmIGVuZ2luZSA9PSAicG9kbWFuIjoKICAgICAgICBlbnZbIlBPRE1BTl9DT01QT1NFX1dBUk5J
  >> "!B64TMP!" echo TkdfTE9HUyJdID0gImZhbHNlIgogICAgICAgIGlmIGNvbXBvc2UgPT0gWyJwb2RtYW4iLCAiY29t
  >> "!B64TMP!" echo cG9zZSJdIGFuZCBub3QgZW5zdXJlX3BvZG1hbl9zb2NrZXQoKToKICAgICAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo IlBvZG1hbidzIEFQSSBzb2NrZXQgaXMgbm90IGFjdGl2ZTsgaWYgY29tcG9zZSBmYWlscywgcnVu
  >> "!B64TMP!" echo OiAiCiAgICAgICAgICAgICAgICAgICJzeXN0ZW1jdGwgLS11c2VyIGVuYWJsZSAtLW5vdyBwb2Rt
  >> "!B64TMP!" echo YW4uc29ja2V0IiwgZmlsZT1zeXMuc3RkZXJyKQoKICAgIHByaW50KGYiU3RhcnRpbmcgc3RhY2sg
  >> "!B64TMP!" echo aW4ge2luc3RhbGxfZGlyfSAoe2NvbXBvc2VfbGFiZWx9KSAuLi4iLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oY29tcG9zZSArIFsidXAiLCAiLWQiXSwgY3dkPWlu
  >> "!B64TMP!" echo c3RhbGxfZGlyLCBlbnY9ZW52KQogICAgaWYgcHJvYy5yZXR1cm5jb2RlICE9IDA6CiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIEZhbHNlLCBmIid7Y29tcG9zZV9sYWJlbH0gdXAgLWQnIGZhaWxlZCDigJQgc2VlIG91
  >> "!B64TMP!" echo dHB1dCBhYm92ZS4iLCAxCgogICAgcHJpbnQoIldhaXRpbmcgZm9yIGVuZHBvaW50cyAuLi4iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICBkZWFkbGluZSA9IHRpbWUudGltZSgpICsgcmVhZHlfdGltZW91
  >> "!B64TMP!" echo dAogICAgd2hpbGUgdGltZS50aW1lKCkgPCBkZWFkbGluZToKICAgICAgICBzdCA9IHN0YXR1cyhl
  >> "!B64TMP!" echo bmRwb2ludHMpCiAgICAgICAgaWYgYWxsKHN0LnZhbHVlcygpKToKICAgICAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IFRydWUsIHJlYWR5X21lc3NhZ2UoZW5kcG9pbnRzKSwgMAogICAgICAgIHRpbWUuc2xlZXAocG9s
  >> "!B64TMP!" echo bF9ldmVyeSkKCiAgICBmb3IgbmFtZSwgdXJsIGluIGVuZHBvaW50cy5pdGVtcygpOgogICAgICAg
  >> "!B64TMP!" echo IG1hcmsgPSAiT0sgICIgaWYgc3RbbmFtZV0gZWxzZSAiRE9XTiIKICAgICAgICBwcmludChmIiAg
  >> "!B64TMP!" echo W3ttYXJrfV0ge0RJU1BMQVlbbmFtZV19IDp7cG9ydF9vZih1cmwpfSIsIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgIHJldHVybiBGYWxzZSwgKGYiU3RhY2sgZGlkIG5vdCBiZWNvbWUgcmVhZHkgd2l0aGlu
  >> "!B64TMP!" echo IHtyZWFkeV90aW1lb3V0fXMuIEluc3BlY3Qgd2l0aDpcbiIKICAgICAgICAgICAgICAgICAgIGYi
  >> "!B64TMP!" echo ICAgIGNkIHtpbnN0YWxsX2Rpcn0gJiYge2NvbXBvc2VfbGFiZWx9IGxvZ3MgLS10YWlsIDUwIiks
  >> "!B64TMP!" echo IDEKCgpkZWYgbWFpbigpOgogICAgYXAgPSBhcmdwYXJzZS5Bcmd1bWVudFBhcnNlcihkZXNjcmlw
  >> "!B64TMP!" echo dGlvbj0iRW5zdXJlIHRoZSBsb2NhbC1zZWFyY2ggY29udGFpbmVyIHN0YWNrIGlzIHJ1bm5pbmcu
  >> "!B64TMP!" echo IikKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1jaGVjayIsIGFjdGlvbj0ic3RvcmVfdHJ1ZSIsCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgaGVscD0ib25seSByZXBvcnQgc3RhdHVzOyBuZXZlciBzdGFydCBh
  >> "!B64TMP!" echo bnl0aGluZyIpCiAgICBhcmdzID0gYXAucGFyc2VfYXJncygpCgogICAgb2ssIG1lc3NhZ2UsIGNv
  >> "!B64TMP!" echo ZGUgPSBlbnN1cmVfcmVhZHkoY2hlY2tfb25seT1hcmdzLmNoZWNrKQogICAgaWYgb2s6CiAgICAg
  >> "!B64TMP!" echo ICAgcHJpbnQobWVzc2FnZSkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQobWVzc2FnZSwgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgcmV0dXJuIGNvZGUKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18i
  >> "!B64TMP!" echo OgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\ensure_stack.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/firecrawl_api.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\firecrawl_api.py" (
  copy /Y "!SRC!\local-web-search\scripts\firecrawl_api.py" "!TARGET!\local-web-search\scripts\firecrawl_api.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\firecrawl_api.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/firecrawl_api.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3812617029.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTaGFyZWQgRmlyZWNyYXdsIEhUVFAgY2xpZW50IGZv
  >> "!B64TMP!" echo ciB0aGUgbG9jYWwtd2ViLXNlYXJjaCB3ZWJfKiBzY3JpcHRzLgoKRXZlcnkgc2NyaXB0IHRoYXQg
  >> "!B64TMP!" echo dGFsa3MgdG8gdGhlIEZpcmVjcmF3bCBBUEkgKHdlYl9zY3JhcGUucHksIHdlYl9tYXAucHksCndl
  >> "!B64TMP!" echo Yl9jcmF3bC5weSwgLi4uIHdlYl9kZXZlbG9wZXJfc2VhcmNoLnB5KSBnb2VzIHRocm91Z2ggdGhp
  >> "!B64TMP!" echo cyBtb2R1bGUsIHdoaWNoCmFkZHMgdGhlIHNhbWUgc2VsZi1oZWFsaW5nIGJlaGF2aW91ciBhcyB3
  >> "!B64TMP!" echo ZWJfc2VhcmNoLnB5IC8gd2ViX3NjcmFwZS5weToKCiAgKiBvbiBhIENPTk5FQ1RJT04gZXJyb3Ig
  >> "!B64TMP!" echo KHN0YWNrIGRvd24pLCB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHN0YXJ0ZWQKICAgIGF1dG9t
  >> "!B64TMP!" echo YXRpY2FsbHkgKGVuc3VyZV9zdGFjay5weSBsb2dpYzogRG9ja2VyIGVuZ2luZSArIGBkb2NrZXIg
  >> "!B64TMP!" echo Y29tcG9zZQogICAgdXAgLWRgKSBhbmQgdGhlIHJlcXVlc3QgaXMgcmV0cmllZCBvbmNlIOKAlCBv
  >> "!B64TMP!" echo bmx5IHdoZW4gdGFsa2luZyB0byB0aGUgTE9DQUwKICAgIHN0YWNrLCBuZXZlciBmb3IgYSByZW1v
  >> "!B64TMP!" echo dGUgRklSRUNSQVdMX0FQSV9VUkwsCiAgKiB0cmFuc2llbnQgSFRUUCBzdGF0dXNlcyAoNDI5IC8g
  >> "!B64TMP!" echo NXh4KSBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZiwKICAqIGV2ZXJ5IGZhaWx1cmUg
  >> "!B64TMP!" echo aXMgcmVwb3J0ZWQgYXMgYW4gRmNFcnJvciB3aXRoIGEgY2xlYXIsIGFjdGlvbmFibGUgbWVzc2Fn
  >> "!B64TMP!" echo ZS4KCkVuZHBvaW50czogdGhlIGJhc2UgVVJMIGRlZmF1bHRzIHRvIHRoZSBsb2NhbCBGaXJlY3Jh
  >> "!B64TMP!" echo d2wgaW5zdGFuY2UgKHBvcnQgZnJvbQpGSVJFQ1JBV0xfUE9SVCBpbiB0aGUgaW5zdGFsbCBmb2xk
  >> "!B64TMP!" echo ZXIncyAuZW52LCBkZWZhdWx0IDk5OTEpLiBUd28gc2V0dGluZ3Mg4oCUCnRoZSBzYW1lIG5hbWVz
  >> "!B64TMP!" echo IHRoZSBvZmZpY2lhbCBmaXJlY3Jhd2wtbWNwIHNlcnZlciB1c2VzIOKAlCBvdmVycmlkZSBpdC4g
  >> "!B64TMP!" echo RWFjaAppcyByZWFkIGZyb20gdGhlIHByb2Nlc3MgZW52aXJvbm1lbnQgRklSU1QsIHRoZW4gZnJv
  >> "!B64TMP!" echo bSB0aGUgaW5zdGFsbCBmb2xkZXIncwouZW52ICh3aGVyZSBpbnN0YWxsLWxvY2FsLXNlYXJjaCBw
  >> "!B64TMP!" echo ZXJzaXN0cyB0aGUgY3JlZGVudGlhbHMgd2hlbiB5b3UgYW5zd2VyCid5JyB0byBpdHMgIkFkZCBh
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBhY2NvdW50PyIgcXVlc3Rpb24pOgoKICBGSVJFQ1JBV0xfQVBJX1VSTCAgICBi
  >> "!B64TMP!" echo YXNlIFVSTCBvZiBhIEZpcmVjcmF3bCBBUEkgKGUuZy4gdGhlIGNsb3VkIEFQSSwKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBodHRwczovL2FwaS5maXJlY3Jhd2wuZGV2KS4gU2V0IHRoaXMgdG8gdXNl
  >> "!B64TMP!" echo IGFjY291bnQKICAgICAgICAgICAgICAgICAgICAgICBmZWF0dXJlcyAoYWdlbnQsIGludGVyYWN0
  >> "!B64TMP!" echo LCBwYXJzZSwgbW9uaXRvcnMsIHJlc2VhcmNoLAogICAgICAgICAgICAgICAgICAgICAgIGRldmVs
  >> "!B64TMP!" echo b3BlciBzZWFyY2gpIHRoYXQgdGhlIHNlbGYtaG9zdGVkIGluc3RhbmNlIGRvZXMKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBub3QgZXhwb3NlLgogIEZJUkVDUkFXTF9BUElfS0VZICAgIHNlbnQgYXMg
  >> "!B64TMP!" echo YEF1dGhvcml6YXRpb246IEJlYXJlciA8a2V5PmAgd2hlbiBzZXQg4oCUCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmVxdWlyZWQgYnkgdGhlIGNsb3VkIEFQSSBhbmQgYWNjb3VudCBmZWF0dXJlcy4K
  >> "!B64TMP!" echo ClVzYWdlIGZyb20gYSBzaWJsaW5nIHNjcmlwdDoKCiAgICBpbXBvcnQgZmlyZWNyYXdsX2FwaSBh
  >> "!B64TMP!" echo cyBmYwogICAgZGF0YSA9IGZjLmNhbGwoIi92MS9tYXAiLCBtZXRob2Q9IlBPU1QiLCBib2R5PXsi
  >> "!B64TMP!" echo dXJsIjogdXJsfSkKCmBjYWxsKClgIHJldHVybnMgdGhlIHBhcnNlZCBKU09OIHJlc3BvbnNlIGFz
  >> "!B64TMP!" echo IGEgZGljdCBhbmQgcmFpc2VzIEZjRXJyb3Igb24KYW55IGZhaWx1cmUgKGFmdGVyIHRoZSByZXRy
  >> "!B64TMP!" echo aWVzIGRlc2NyaWJlZCBhYm92ZSkuCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5
  >> "!B64TMP!" echo cwppbXBvcnQgdGltZQppbXBvcnQgdXJsbGliLmVycm9yCmltcG9ydCB1cmxsaWIucGFyc2UKaW1w
  >> "!B64TMP!" echo b3J0IHVybGxpYi5yZXF1ZXN0CgojIERlZmF1bHQgc3Rkb3V0L3N0ZGVyciB0byBVVEYtOCByZWdh
  >> "!B64TMP!" echo cmRsZXNzIG9mIHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQojIChlLmcuIFdpbmRvd3MgY3AxMjUy
  >> "!B64TMP!" echo KSwgc28gZXJyb3IgbWVzc2FnZXMgYW5kIHByb2dyZXNzIG91dHB1dCBjb250YWluaW5nCiMgbm9u
  >> "!B64TMP!" echo LUFTQ0lJIHRleHQgbmV2ZXIgY3Jhc2ggd2l0aCBhIFVuaWNvZGVFbmNvZGVFcnJvci4gU2tpcHBl
  >> "!B64TMP!" echo ZCBpZgojIFBZVEhPTklPRU5DT0RJTkcgaXMgYWxyZWFkeSBzZXQg4oCUIGFuIGV4cGxpY2l0IG92
  >> "!B64TMP!" echo ZXJyaWRlIGFsd2F5cyB3aW5zLgppZiAiUFlUSE9OSU9FTkNPRElORyIgbm90IGluIG9zLmVudmly
  >> "!B64TMP!" echo b246CiAgICBmb3IgX3N0cmVhbSBpbiAoc3lzLnN0ZG91dCwgc3lzLnN0ZGVycik6CiAgICAgICAg
  >> "!B64TMP!" echo aWYgaGFzYXR0cihfc3RyZWFtLCAicmVjb25maWd1cmUiKToKICAgICAgICAgICAgdHJ5OgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgX3N0cmVhbS5yZWNvbmZpZ3VyZShlbmNvZGluZz0idXRmLTgiKQogICAgICAg
  >> "!B64TMP!" echo ICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgcGFzcwoKc3lzLnBhdGguaW5z
  >> "!B64TMP!" echo ZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0
  >> "!B64TMP!" echo IGNvbmZpZyAgIyBzaWJsaW5nIG1vZHVsZTogaW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1kcml2
  >> "!B64TMP!" echo ZW4gZW5kcG9pbnRzCgojIERlZmF1bHQgdGltZW91dCBwZXIgSFRUUCBhdHRlbXB0IChzZWNvbmRz
  >> "!B64TMP!" echo KTsgY2FsbGVycyBjYW4gb3ZlcnJpZGUuClRJTUVPVVQgPSA5MAoKIyBUcmFuc2llbnQgc3RhdHVz
  >> "!B64TMP!" echo ZXMgd29ydGggcmV0cnlpbmc6IHJhdGUgbGltaXQgKyBjb21tb24gc2VydmVyIGVycm9ycy4KUkVU
  >> "!B64TMP!" echo UllfU1RBVFVTRVMgPSAoNDI5LCA1MDAsIDUwMiwgNTAzLCA1MDQpCiMgQmFja29mZiBiZWZvcmUg
  >> "!B64TMP!" echo ZWFjaCByZXRyeSAoc2Vjb25kcyk6IG9uZSBlbnRyeSBwZXIgcmV0cnkuClJFVFJZX0JBQ0tPRkYg
  >> "!B64TMP!" echo PSAoMSwgMykKCiMgQ2FjaGVkIHZpZXcgb2YgdGhlIGluc3RhbGwgZm9sZGVyJ3MgLmVudiAobGF6
  >> "!B64TMP!" echo aWx5IGNvbXB1dGVkIG9uY2U6IHJlc29sdmluZwojIHRoZSBpbnN0YWxsIGZvbGRlciBtYXkgcXVl
  >> "!B64TMP!" echo cnkgRG9ja2VyKS4gSG9sZHMgdGhlIEZJUkVDUkFXTF9BUElfVVJMIC8KIyBGSVJFQ1JBV0xfQVBJ
  >> "!B64TMP!" echo X0tFWSB2YWx1ZXMgdGhlIGluc3RhbGxlciB3cm90ZSB3aGVuIGEgRmlyZWNyYXdsIGFjY291bnQg
  >> "!B64TMP!" echo d2FzCiMgY29uZmlndXJlZCBhdCBpbnN0YWxsIHRpbWUuCl9JTlNUQUxMX0VOViA9IE5vbmUKCgpk
  >> "!B64TMP!" echo ZWYgX2luc3RhbGxfZW52KCk6CiAgICAiIiJUaGUgaW5zdGFsbCBmb2xkZXIncyAuZW52IGFzIGEg
  >> "!B64TMP!" echo ZGljdCAoc2VlIGNvbmZpZy5sb2FkX2VudiksIGNhY2hlZC4iIiIKICAgIGdsb2JhbCBfSU5TVEFM
  >> "!B64TMP!" echo TF9FTlYKICAgIGlmIF9JTlNUQUxMX0VOViBpcyBOb25lOgogICAgICAgIHRyeToKICAgICAgICAg
  >> "!B64TMP!" echo ICAgX0lOU1RBTExfRU5WID0gY29uZmlnLmxvYWRfZW52KGNvbmZpZy5maW5kX2luc3RhbGxfZGly
  >> "!B64TMP!" echo KCkpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgX0lOU1RBTExfRU5WID0g
  >> "!B64TMP!" echo e30KICAgIHJldHVybiBfSU5TVEFMTF9FTlYKCgpkZWYgX3NldHRpbmcobmFtZSk6CiAgICAiIiJW
  >> "!B64TMP!" echo YWx1ZSBvZiBGSVJFQ1JBV0xfQVBJX1VSTCAvIEZJUkVDUkFXTF9BUElfS0VZOiB0aGUgcHJvY2Vz
  >> "!B64TMP!" echo cwogICAgZW52aXJvbm1lbnQgZmlyc3QgKHRoZSBzYW1lIG92ZXJyaWRlIHRoZSBvZmZpY2lhbCBm
  >> "!B64TMP!" echo aXJlY3Jhd2wtbWNwIHNlcnZlcgogICAgaG9ub3VycyksIHRoZW4gdGhlIGluc3RhbGwgZm9sZGVy
  >> "!B64TMP!" echo J3MgLmVudi4gU3RyaXBwZWQsIHBvc3NpYmx5IGVtcHR5LiIiIgogICAgdmFsID0gKG9zLmVudmly
  >> "!B64TMP!" echo b24uZ2V0KG5hbWUpIG9yICIiKS5zdHJpcCgpCiAgICBpZiB2YWw6CiAgICAgICAgcmV0dXJuIHZh
  >> "!B64TMP!" echo bAogICAgcmV0dXJuIChfaW5zdGFsbF9lbnYoKS5nZXQobmFtZSkgb3IgIiIpLnN0cmlwKCkKCgpj
  >> "!B64TMP!" echo bGFzcyBGY0Vycm9yKEV4Y2VwdGlvbik6CiAgICAiIiJBIEZpcmVjcmF3bCBBUEkgZmFpbHVyZSBh
  >> "!B64TMP!" echo ZnRlciBhbGwgcmV0cmllcywgd2l0aCBhIHVzZXItZmFjaW5nIGhpbnQuCgogICAgQXR0cmlidXRl
  >> "!B64TMP!" echo czoKICAgICAgICBtZXNzYWdlICB3aGF0IHdlbnQgd3JvbmcgKHNpbmdsZSBsaW5lKQogICAgICAg
  >> "!B64TMP!" echo IHN0YXR1cyAgIEhUVFAgc3RhdHVzIGNvZGUsIG9yIE5vbmUgZm9yIGNvbm5lY3Rpb24vcHJvdG9j
  >> "!B64TMP!" echo b2wgZXJyb3JzCiAgICAgICAgaGludCAgICAgb3B0aW9uYWwgZXh0cmEgZ3VpZGFuY2UgcHJpbnRl
  >> "!B64TMP!" echo ZCBieSB0aGUgQ0xJIHNjcmlwdHMKICAgICIiIgoKICAgIGRlZiBfX2luaXRfXyhzZWxmLCBtZXNz
  >> "!B64TMP!" echo YWdlLCBzdGF0dXM9Tm9uZSwgaGludD1Ob25lKToKICAgICAgICBzdXBlcigpLl9faW5pdF9fKG1l
  >> "!B64TMP!" echo c3NhZ2UpCiAgICAgICAgc2VsZi5zdGF0dXMgPSBzdGF0dXMKICAgICAgICBzZWxmLmhpbnQgPSBo
  >> "!B64TMP!" echo aW50CgoKZGVmIGJhc2VfdXJsKCk6CiAgICAiIiJUaGUgRmlyZWNyYXdsIGJhc2UgVVJMOiBGSVJF
  >> "!B64TMP!" echo Q1JBV0xfQVBJX1VSTCB3aGVuIHNldCBpbiB0aGUgZW52aXJvbm1lbnQKICAgIG9yIHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsIGZvbGRlcidzIC5lbnYgKHNlbGYtaG9zdGVkIHJlbW90ZSBvciB0aGUgY2xvdWQgQVBJKSwK
  >> "!B64TMP!" echo ICAgIG90aGVyd2lzZSB0aGUgbG9jYWwgc3RhY2sncyBlbmRwb2ludCAoRklSRUNSQVdMX1BPUlQg
  >> "!B64TMP!" echo ZnJvbSB0aGUgaW5zdGFsbAogICAgZm9sZGVyJ3MgLmVudiwgZGVmYXVsdCA5OTkxKS4iIiIKICAg
  >> "!B64TMP!" echo IG92ZXJyaWRlID0gX3NldHRpbmcoIkZJUkVDUkFXTF9BUElfVVJMIikKICAgIGlmIG92ZXJyaWRl
  >> "!B64TMP!" echo OgogICAgICAgIHJldHVybiBvdmVycmlkZS5yc3RyaXAoIi8iKQogICAgcmV0dXJuIGNvbmZpZy5l
  >> "!B64TMP!" echo bmRwb2ludHMoY29uZmlnLmZpbmRfaW5zdGFsbF9kaXIoKSlbImZpcmVjcmF3bCJdCgoKZGVmIGlz
  >> "!B64TMP!" echo X2xvY2FsKCk6CiAgICAiIiJUcnVlIHdoZW4gcmVxdWVzdHMgZ28gdG8gdGhlIExPQ0FMIHN0YWNr
  >> "!B64TMP!" echo IChubyBGSVJFQ1JBV0xfQVBJX1VSTCBpbiB0aGUKICAgIGVudmlyb25tZW50IG9yIHRoZSBpbnN0
  >> "!B64TMP!" echo YWxsIGZvbGRlcidzIC5lbnYpLCBpLmUuIHNlbGYtaGVhbGluZyBhIGRvd24KICAgIHN0YWNrIGNh
  >> "!B64TMP!" echo biBoZWxwLiIiIgogICAgcmV0dXJuIG5vdCBfc2V0dGluZygiRklSRUNSQVdMX0FQSV9VUkwiKQoK
  >> "!B64TMP!" echo CmRlZiB1cmwocGF0aCk6CiAgICAiIiJBYnNvbHV0ZSBVUkwgZm9yIGFuIEFQSSBwYXRoIGxpa2Ug
  >> "!B64TMP!" echo Jy92MS9tYXAnIChzZWUgYmFzZV91cmwoKSkuIiIiCiAgICByZXR1cm4gYmFzZV91cmwoKSArIHBh
  >> "!B64TMP!" echo dGgKCgpkZWYgYXV0aF9oZWFkZXJzKCk6CiAgICAiIiJIZWFkZXJzIGZvciBhIEpTT04gcmVxdWVz
  >> "!B64TMP!" echo dDogY29udGVudCB0eXBlICsgb3B0aW9uYWwgQmVhcmVyIGF1dGggZnJvbQogICAgRklSRUNSQVdM
  >> "!B64TMP!" echo X0FQSV9LRVkgKGVudmlyb25tZW50IG9yIGluc3RhbGwgLmVudjsgbmVlZGVkIGZvciBhY2NvdW50
  >> "!B64TMP!" echo CiAgICBmZWF0dXJlcyAvIHRoZSBjbG91ZCBBUEkpLiIiIgogICAgaGVhZGVycyA9IHsiQ29udGVu
  >> "!B64TMP!" echo dC1UeXBlIjogImFwcGxpY2F0aW9uL2pzb24ifQogICAga2V5ID0gX3NldHRpbmcoIkZJUkVDUkFX
  >> "!B64TMP!" echo TF9BUElfS0VZIikKICAgIGlmIGtleToKICAgICAgICBoZWFkZXJzWyJBdXRob3JpemF0aW9uIl0g
  >> "!B64TMP!" echo PSAiQmVhcmVyICIgKyBrZXkKICAgIHJldHVybiBoZWFkZXJzCgoKZGVmIF9zZWxmaGVhbCgpOgog
  >> "!B64TMP!" echo ICAgIiIiU3RhcnQgdGhlIGNvbnRhaW5lciBlbmdpbmUgKyB0aGUgY29udGFpbmVycyBpZiB0aGV5
  >> "!B64TMP!" echo IGFyZSBkb3duICh0aGUgc2FtZQogICAgbG9naWMgYXMgZW5zdXJlX3N0YWNrLnB5KS4gSW1wb3J0
  >> "!B64TMP!" echo IGlzIGRlZmVycmVkIHNvIHRoZSBmYXN0IHBhdGggKHN0YWNrCiAgICBhbHJlYWR5IHVwKSBwYXlz
  >> "!B64TMP!" echo IG5vdGhpbmcuIFJldHVybnMgKG9rLCBtZXNzYWdlKS4iIiIKICAgIHRyeToKICAgICAgICBpbXBv
  >> "!B64TMP!" echo cnQgZW5zdXJlX3N0YWNrCiAgICAgICAgb2ssIG1lc3NhZ2UsIF9jb2RlID0gZW5zdXJlX3N0YWNr
  >> "!B64TMP!" echo LmVuc3VyZV9yZWFkeSgpCiAgICAgICAgcmV0dXJuIG9rLCBtZXNzYWdlCiAgICBleGNlcHQgRXhj
  >> "!B64TMP!" echo ZXB0aW9uIGFzIGU6ICAjIHVuZXhwZWN0ZWQgc2VsZi1oZWFsIGZhaWx1cmU6IGRlZ3JhZGUgZ3Jh
  >> "!B64TMP!" echo Y2VmdWxseQogICAgICAgIHJldHVybiBGYWxzZSwgInNlbGYtaGVhbCBmYWlsZWQgdW5leHBlY3Rl
  >> "!B64TMP!" echo ZGx5OiB7fSIuZm9ybWF0KGUpCgoKZGVmIF9yZWFkX2JvZHkoZSk6CiAgICAiIiJCZXN0LWVmZm9y
  >> "!B64TMP!" echo dCBlcnJvciBib2R5IGZyb20gYW4gSFRUUEVycm9yIChKU09OIG1lc3NhZ2Ugb3IgcmF3IHRleHQp
  >> "!B64TMP!" echo LiIiIgogICAgdHJ5OgogICAgICAgIHJhdyA9IGUucmVhZCgpCiAgICBleGNlcHQgRXhjZXB0aW9u
  >> "!B64TMP!" echo OgogICAgICAgIHJldHVybiAiIgogICAgdGV4dCA9IHJhdy5kZWNvZGUoInV0Zi04IiwgInJlcGxh
  >> "!B64TMP!" echo Y2UiKVs6ODAwXQogICAgdHJ5OgogICAgICAgIHBheWxvYWQgPSBqc29uLmxvYWRzKHRleHQpCiAg
  >> "!B64TMP!" echo ICAgICAgbXNnID0gcGF5bG9hZC5nZXQoImVycm9yIikgb3IgcGF5bG9hZC5nZXQoIm1lc3NhZ2Ui
  >> "!B64TMP!" echo KQogICAgICAgIGlmIGlzaW5zdGFuY2UobXNnLCBzdHIpIGFuZCBtc2c6CiAgICAgICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiBtc2cKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcGFzcwogICAgcmV0dXJuIHRl
  >> "!B64TMP!" echo eHQKCgpkZWYgX2hpbnRfZm9yX3N0YXR1cyhzdGF0dXMpOgogICAgIiIiQWN0aW9uYWJsZSBndWlk
  >> "!B64TMP!" echo YW5jZSBmb3IgdGhlIHN0YXR1c2VzIGFjY291bnQtZ2F0ZWQgZW5kcG9pbnRzIHJldHVybi4iIiIK
  >> "!B64TMP!" echo ICAgIGlmIHN0YXR1cyBpbiAoNDAxLCA0MDMpOgogICAgICAgIHJldHVybiAoIlRoaXMgdG9vbCBu
  >> "!B64TMP!" echo ZWVkcyBhbiBhdXRoZW50aWNhdGVkIEZpcmVjcmF3bCBhY2NvdW50OiBzZXQgIgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIkZJUkVDUkFXTF9BUElfS0VZIChhbmQgRklSRUNSQVdMX0FQSV9VUkw9aHR0cHM6Ly9h
  >> "!B64TMP!" echo cGkuZmlyZWNyYXdsLmRldiAiCiAgICAgICAgICAgICAgICAidG8gdXNlIHRoZSBjbG91ZCBBUEkp
  >> "!B64TMP!" echo IGFuZCByZXRyeS4iKQogICAgaWYgc3RhdHVzID09IDQwNDoKICAgICAgICByZXR1cm4gKCJUaGlz
  >> "!B64TMP!" echo IGVuZHBvaW50IGlzIG5vdCBhdmFpbGFibGUgb24gdGhlIEZpcmVjcmF3bCBpbnN0YW5jZSBpdCAi
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICAid2FzIGNhbGxlZCBhZ2FpbnN0LiBBY2NvdW50IHRvb2xzIChtb25p
  >> "!B64TMP!" echo dG9yIC8gcmVzZWFyY2ggLyAiCiAgICAgICAgICAgICAgICAiZGV2ZWxvcGVyIHNlYXJjaCkgbmVl
  >> "!B64TMP!" echo ZCB0aGUgY2xvdWQgQVBJOiBzZXQgIgogICAgICAgICAgICAgICAgIkZJUkVDUkFXTF9BUElfVVJM
  >> "!B64TMP!" echo PWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgYW5kICIKICAgICAgICAgICAgICAgICJGSVJFQ1JB
  >> "!B64TMP!" echo V0xfQVBJX0tFWSwgdGhlbiByZXRyeS4iKQogICAgaWYgc3RhdHVzIGluIFJFVFJZX1NUQVRVU0VT
  >> "!B64TMP!" echo OgogICAgICAgIHJldHVybiAoIlRoZSBGaXJlY3Jhd2wgc2VydmljZSBhbnN3ZXJlZCB3aXRoIGEg
  >> "!B64TMP!" echo c2VydmVyIGVycm9yLiBXYWl0IGEgIgogICAgICAgICAgICAgICAgIm1vbWVudCBhbmQgcmV0cnk7
  >> "!B64TMP!" echo IGlmIGl0IHBlcnNpc3RzLCBpbnNwZWN0IHRoZSBzdGFjayB3aXRoOiAiCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiY2QgPGluc3RhbGwgZm9sZGVyPiAmJiBkb2NrZXIgY29tcG9zZSBsb2dzIC0tdGFpbCA1MCBm
  >> "!B64TMP!" echo aXJlY3Jhd2wgIgogICAgICAgICAgICAgICAgIihvciBgcG9kbWFuIGNvbXBvc2UgbG9ncyAuLi5g
  >> "!B64TMP!" echo IGlmIHRoZSBzdGFjayBydW5zIG9uIFBvZG1hbikiKQogICAgcmV0dXJuIE5vbmUKCgpkZWYgX3Jl
  >> "!B64TMP!" echo cXVlc3QoZW5kcG9pbnQsIG1ldGhvZCwgYm9keV9ieXRlcywgaGVhZGVycywgdGltZW91dCk6CiAg
  >> "!B64TMP!" echo ICAiIiJPbmUgcmF3IEhUVFAgYXR0ZW1wdC4gUmFpc2VzIEhUVFBFcnJvciAoc2VydmljZSBhbnN3
  >> "!B64TMP!" echo ZXJlZCB3aXRoIGFuCiAgICBlcnJvciBzdGF0dXMg4oCUIHNlcnZpY2UgaXMgVVApIG9yIFVSTEVy
  >> "!B64TMP!" echo cm9yLWZhbWlseSAoY29ubmVjdGlvbiBwcm9ibGVtIOKAlAogICAgc2VydmljZSBpcyBET1dOKS4g
  >> "!B64TMP!" echo UmV0dXJucyB0aGUgcGFyc2VkIEpTT04gcmVzcG9uc2UuIiIiCiAgICByZXEgPSB1cmxsaWIucmVx
  >> "!B64TMP!" echo dWVzdC5SZXF1ZXN0KGVuZHBvaW50LCBkYXRhPWJvZHlfYnl0ZXMsCiAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIGhlYWRlcnM9aGVhZGVycywgbWV0aG9kPW1ldGhvZCkKICAgIHdpdGgg
  >> "!B64TMP!" echo dXJsbGliLnJlcXVlc3QudXJsb3BlbihyZXEsIHRpbWVvdXQ9dGltZW91dCkgYXMgcjoKICAgICAg
  >> "!B64TMP!" echo ICB0ZXh0ID0gci5yZWFkKCkuZGVjb2RlKCJ1dGYtOCIsICJyZXBsYWNlIikKICAgIGlmIG5vdCB0
  >> "!B64TMP!" echo ZXh0LnN0cmlwKCk6CiAgICAgICAgcmV0dXJuIHt9CiAgICB0cnk6CiAgICAgICAgcmV0dXJuIGpz
  >> "!B64TMP!" echo b24ubG9hZHModGV4dCkKICAgIGV4Y2VwdCBWYWx1ZUVycm9yOgogICAgICAgIHJhaXNlIEZjRXJy
  >> "!B64TMP!" echo b3IoIkZpcmVjcmF3bCByZXR1cm5lZCBhIG5vbi1KU09OIHJlc3BvbnNlOiAiCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICArIHRleHRbOjMwMF0pCgoKZGVmIGNhbGwocGF0aCwgbWV0aG9kPSJHRVQiLCBi
  >> "!B64TMP!" echo b2R5PU5vbmUsIHF1ZXJ5PU5vbmUsIHRpbWVvdXQ9VElNRU9VVCk6CiAgICAiIiJDYWxsIHRoZSBG
  >> "!B64TMP!" echo aXJlY3Jhd2wgQVBJIHdpdGggcmV0cmllcyArIHNlbGYtaGVhbGluZy4KCiAgICBwYXRoICAgIEFQ
  >> "!B64TMP!" echo SSBwYXRoLCBlLmcuICIvdjEvbWFwIiBvciAiL3YxL2NyYXdsLzxpZD4iIChhbHJlYWR5IGVuY29k
  >> "!B64TMP!" echo ZWQpCiAgICBtZXRob2QgIEhUVFAgbWV0aG9kIChHRVQgLyBQT1NUIC8gUEFUQ0ggLyBERUxFVEUp
  >> "!B64TMP!" echo CiAgICBib2R5ICAgIEpTT04tc2VyaWFsaXNhYmxlIHJlcXVlc3QgYm9keSAoZGljdCkgb3IgTm9u
  >> "!B64TMP!" echo ZQogICAgcXVlcnkgICBkaWN0IG9mIHF1ZXJ5LXN0cmluZyBwYXJhbWV0ZXJzIChza2lwcGVkIHdo
  >> "!B64TMP!" echo ZW4gZW1wdHkvTm9uZSkKICAgIHRpbWVvdXQgc2Vjb25kcyBwZXIgSFRUUCBhdHRlbXB0CgogICAg
  >> "!B64TMP!" echo UmV0dXJucyB0aGUgcGFyc2VkIEpTT04gcmVzcG9uc2UgKGRpY3QpLiBSYWlzZXMgRmNFcnJvciBh
  >> "!B64TMP!" echo ZnRlciB0aGUKICAgIHJldHJpZXMgYXJlIGV4aGF1c3RlZCAoc2VlIG1vZHVsZSBkb2NzdHJpbmcg
  >> "!B64TMP!" echo Zm9yIHRoZSByZXRyeSBwb2xpY3kpLiIiIgogICAgZW5kcG9pbnQgPSB1cmwocGF0aCkKICAgIGlm
  >> "!B64TMP!" echo IHF1ZXJ5OgogICAgICAgIHBhaXJzID0gWyhrLCB2KSBmb3IgaywgdiBpbiBxdWVyeS5pdGVtcygp
  >> "!B64TMP!" echo IGlmIHYgaXMgbm90IE5vbmVdCiAgICAgICAgaWYgcGFpcnM6CiAgICAgICAgICAgIGVuZHBvaW50
  >> "!B64TMP!" echo ICs9ICI/IiArIHVybGxpYi5wYXJzZS51cmxlbmNvZGUocGFpcnMpCiAgICBib2R5X2J5dGVzID0g
  >> "!B64TMP!" echo Tm9uZQogICAgaGVhZGVycyA9IGF1dGhfaGVhZGVycygpCiAgICBpZiBib2R5IGlzIG5vdCBOb25l
  >> "!B64TMP!" echo OgogICAgICAgIGJvZHlfYnl0ZXMgPSBqc29uLmR1bXBzKGJvZHkpLmVuY29kZSgidXRmLTgiKQoK
  >> "!B64TMP!" echo ICAgIGF0dGVtcHRzID0gMSArIGxlbihSRVRSWV9CQUNLT0ZGKSAgIyBpbml0aWFsICsgcmV0cmll
  >> "!B64TMP!" echo cwogICAgZm9yIGF0dGVtcHQgaW4gcmFuZ2UoMSwgYXR0ZW1wdHMgKyAxKToKICAgICAgICAjIC0t
  >> "!B64TMP!" echo LS0gb25lIGF0dGVtcHQsIGNsYXNzaWZ5aW5nIGV2ZXJ5IGZhaWx1cmUgbW9kZSAtLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLQogICAgICAgIHRyeToKICAgICAgICAgICAgcmV0dXJuIF9yZXF1ZXN0KGVuZHBvaW50
  >> "!B64TMP!" echo LCBtZXRob2QsIGJvZHlfYnl0ZXMsIGhlYWRlcnMsIHRpbWVvdXQpCiAgICAgICAgZXhjZXB0IHVy
  >> "!B64TMP!" echo bGxpYi5lcnJvci5IVFRQRXJyb3IgYXMgZToKICAgICAgICAgICAgc3RhdHVzID0gZS5jb2RlCiAg
  >> "!B64TMP!" echo ICAgICAgICAgIGRldGFpbCA9IF9yZWFkX2JvZHkoZSkKICAgICAgICAgICAgaWYgc3RhdHVzIGlu
  >> "!B64TMP!" echo IFJFVFJZX1NUQVRVU0VTIGFuZCBhdHRlbXB0IDwgYXR0ZW1wdHM6CiAgICAgICAgICAgICAgICB3
  >> "!B64TMP!" echo YWl0ID0gUkVUUllfQkFDS09GRlthdHRlbXB0IC0gMV0KICAgICAgICAgICAgICAgIHByaW50KGYi
  >> "!B64TMP!" echo RmlyZWNyYXdsIGFuc3dlcmVkIHtzdGF0dXN9ICh7ZGV0YWlsIG9yICdzZXJ2ZXIgZXJyb3InfSkg
  >> "!B64TMP!" echo IgogICAgICAgICAgICAgICAgICAgICAgZiLigJQgcmV0cnlpbmcgaW4ge3dhaXR9cyAuLi4iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgICAgICB0aW1lLnNsZWVwKHdhaXQpCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBjb250aW51ZQogICAgICAgICAgICByYWlzZSBGY0Vycm9yKCJIVFRQIHt9e317fSIu
  >> "!B64TMP!" echo Zm9ybWF0KAogICAgICAgICAgICAgICAgc3RhdHVzLCAiOiAiICsgZGV0YWlsIGlmIGRldGFpbCBl
  >> "!B64TMP!" echo bHNlICIiLAogICAgICAgICAgICAgICAgIiIgaWYgYXR0ZW1wdCA9PSAxIGVsc2UgZiIgKGFmdGVy
  >> "!B64TMP!" echo IHthdHRlbXB0fSBhdHRlbXB0cykiKSwKICAgICAgICAgICAgICAgIHN0YXR1cz1zdGF0dXMsIGhp
  >> "!B64TMP!" echo bnQ9X2hpbnRfZm9yX3N0YXR1cyhzdGF0dXMpKSBmcm9tIGUKICAgICAgICBleGNlcHQgRmNFcnJv
  >> "!B64TMP!" echo cjoKICAgICAgICAgICAgcmFpc2UKICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6ICAjIFVS
  >> "!B64TMP!" echo TEVycm9yIC8gQ29ubmVjdGlvbkVycm9yIC8gdGltZW91dDogRE9XTgogICAgICAgICAgICBpZiBu
  >> "!B64TMP!" echo b3QgaXNfbG9jYWwoKToKICAgICAgICAgICAgICAgIHJhaXNlIEZjRXJyb3IoCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgImNvdWxkIG5vdCByZWFjaCB7fSAoe30pLiBDaGVjayB0aGUgVVJMIGFuZCB5b3Vy
  >> "!B64TMP!" echo ICIKICAgICAgICAgICAgICAgICAgICAibmV0d29yaywgdGhlbiByZXRyeS4iLmZvcm1hdChiYXNl
  >> "!B64TMP!" echo X3VybCgpLCBlKSkgZnJvbSBlCiAgICAgICAgICAgIGlmIGF0dGVtcHQgPCBhdHRlbXB0czoKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICMgTG9jYWwgc3RhY2s6IHRyeSB0byBicmluZyBpdCB1cCwgdGhlbiByZXRy
  >> "!B64TMP!" echo eSB0aGUgcmVxdWVzdC4KICAgICAgICAgICAgICAgIHByaW50KGYiU3RhY2sgdW5yZWFjaGFibGUg
  >> "!B64TMP!" echo KHtlfSkg4oCUIHN0YXJ0aW5nIGl0IGF1dG9tYXRpY2FsbHkgLi4uIiwKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgICAgIG9rLCBtZXNzYWdlID0gX3Nl
  >> "!B64TMP!" echo bGZoZWFsKCkKICAgICAgICAgICAgICAgIGlmIG5vdCBvazoKICAgICAgICAgICAgICAgICAgICBy
  >> "!B64TMP!" echo YWlzZSBGY0Vycm9yKAogICAgICAgICAgICAgICAgICAgICAgICAidGhlIGxvY2FsLXNlYXJjaCBz
  >> "!B64TMP!" echo dGFjayBjb3VsZCBub3QgYmUgc3RhcnRlZDogIiArIG1lc3NhZ2UKICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgKyAiIFJlc29sdmUgdGhlIHN0YWNrIChvciBhc2sgdGhlIHVzZXIgdG8gc3RhcnQgUG9k
  >> "!B64TMP!" echo bWFuL0RvY2tlciAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgIkRlc2t0b3ApIGFuZCByZXRy
  >> "!B64TMP!" echo eSDigJQgZG8gTk9UIGZhbGwgYmFjayB0byBvdGhlciB3ZWIgIgogICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICJ0b29scyB1bmxlc3MgdGhlIHVzZXIgYXNrcy4iKSBmcm9tIGUKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIGNvbnRpbnVlCiAgICAgICAgICAgIHJhaXNlIEZjRXJyb3IoCiAgICAgICAgICAgICAgICAi
  >> "!B64TMP!" echo cmVxdWVzdCBmYWlsZWQgYWZ0ZXIgdGhlIHN0YWNrIHdhcyBzdGFydGVkOiB7fSIuZm9ybWF0KGUp
  >> "!B64TMP!" echo KSBmcm9tIGUKICAgICMgdW5yZWFjaGFibGU6IHRoZSBsb29wIGVpdGhlciByZXR1cm5zIG9yIHJh
  >> "!B64TMP!" echo aXNlcwogICAgcmFpc2UgRmNFcnJvcigicmVxdWVzdCBmYWlsZWQgdW5leHBlY3RlZGx5IikKCgpk
  >> "!B64TMP!" echo ZWYgY2FsbF9mb3JtKHBhdGgsIGZpZWxkcywgZmlsZV9wYXRoLCBmaWxlX2ZpZWxkPSJmaWxlIiwg
  >> "!B64TMP!" echo dGltZW91dD1USU1FT1VUKToKICAgICIiIkNhbGwgdGhlIEZpcmVjcmF3bCBBUEkgd2l0aCBhIG11
  >> "!B64TMP!" echo bHRpcGFydC9mb3JtLWRhdGEgYm9keSAodXNlZCBieQogICAgd2ViX3BhcnNlLnB5IHRvIHVwbG9h
  >> "!B64TMP!" echo ZCBhIGxvY2FsIGRvY3VtZW50KS4KCiAgICBmaWVsZHMgICAgICBkaWN0IG9mIGZvcm0gZmllbGRz
  >> "!B64TMP!" echo ICh2YWx1ZXMgYXJlIHN0ciAvIGludCAvIGxpc3QpCiAgICBmaWxlX3BhdGggICB0aGUgZmlsZSB0
  >> "!B64TMP!" echo byB1cGxvYWQgKHJlYWQgaW4gYmluYXJ5IG1vZGUpCiAgICBmaWxlX2ZpZWxkICB0aGUgZm9ybSBm
  >> "!B64TMP!" echo aWVsZCBuYW1lIGZvciB0aGUgZmlsZSAoRmlyZWNyYXdsOiAiZmlsZSIpCiAgICAiIiIKICAgIGJv
  >> "!B64TMP!" echo dW5kYXJ5ID0gIi0tLS1sb2NhbHdlYnNlYXJjaCIgKyBmb3JtYXQoaW50KHRpbWUudGltZSgpICog
  >> "!B64TMP!" echo MTAwMCksICJ4IikKICAgIHBhcnRzID0gW10KICAgIGZvciBrZXksIHZhbCBpbiAoZmllbGRzIG9y
  >> "!B64TMP!" echo IHt9KS5pdGVtcygpOgogICAgICAgIGlmIHZhbCBpcyBOb25lOgogICAgICAgICAgICBjb250aW51
  >> "!B64TMP!" echo ZQogICAgICAgIHZhbHVlcyA9IHZhbCBpZiBpc2luc3RhbmNlKHZhbCwgbGlzdCkgZWxzZSBbdmFs
  >> "!B64TMP!" echo XQogICAgICAgIGZvciB2IGluIHZhbHVlczoKICAgICAgICAgICAgcGFydHMuYXBwZW5kKCgiLS0i
  >> "!B64TMP!" echo ICsgYm91bmRhcnkpLmVuY29kZSgidXRmLTgiKSkKICAgICAgICAgICAgcGFydHMuYXBwZW5kKCgn
  >> "!B64TMP!" echo Q29udGVudC1EaXNwb3NpdGlvbjogZm9ybS1kYXRhOyBuYW1lPSJ7fSInCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgLmZvcm1hdChrZXkpKS5lbmNvZGUoInV0Zi04IikpCiAgICAgICAgICAgIHBh
  >> "!B64TMP!" echo cnRzLmFwcGVuZChiIiIpCiAgICAgICAgICAgIHBhcnRzLmFwcGVuZChzdHIodikuZW5jb2RlKCJ1
  >> "!B64TMP!" echo dGYtOCIpKQogICAgdHJ5OgogICAgICAgIHdpdGggb3BlbihmaWxlX3BhdGgsICJyYiIpIGFzIGZo
  >> "!B64TMP!" echo OgogICAgICAgICAgICBwYXlsb2FkID0gZmgucmVhZCgpCiAgICBleGNlcHQgT1NFcnJvciBhcyBl
  >> "!B64TMP!" echo OgogICAgICAgIHJhaXNlIEZjRXJyb3IoImNvdWxkIG5vdCByZWFkIHt9OiB7fSIuZm9ybWF0KGZp
  >> "!B64TMP!" echo bGVfcGF0aCwgZSkpCiAgICBmaWxlbmFtZSA9IG9zLnBhdGguYmFzZW5hbWUoZmlsZV9wYXRoKQog
  >> "!B64TMP!" echo ICAgcGFydHMuYXBwZW5kKCgiLS0iICsgYm91bmRhcnkpLmVuY29kZSgidXRmLTgiKSkKICAgIHBh
  >> "!B64TMP!" echo cnRzLmFwcGVuZCgoJ0NvbnRlbnQtRGlzcG9zaXRpb246IGZvcm0tZGF0YTsgbmFtZT0ie30iOyBm
  >> "!B64TMP!" echo aWxlbmFtZT0ie30iJwogICAgICAgICAgICAgICAgICAuZm9ybWF0KGZpbGVfZmllbGQsIGZpbGVu
  >> "!B64TMP!" echo YW1lKSkuZW5jb2RlKCJ1dGYtOCIpKQogICAgcGFydHMuYXBwZW5kKGIiQ29udGVudC1UeXBlOiBh
  >> "!B64TMP!" echo cHBsaWNhdGlvbi9vY3RldC1zdHJlYW0iKQogICAgcGFydHMuYXBwZW5kKGIiIikKICAgIHBhcnRz
  >> "!B64TMP!" echo LmFwcGVuZChwYXlsb2FkKQogICAgcGFydHMuYXBwZW5kKCgiLS0iICsgYm91bmRhcnkgKyAiLS0i
  >> "!B64TMP!" echo KS5lbmNvZGUoInV0Zi04IikpCiAgICBib2R5ID0gYiJcclxuIi5qb2luKHBhcnRzKQoKICAgIGVu
  >> "!B64TMP!" echo ZHBvaW50ID0gdXJsKHBhdGgpCiAgICBoZWFkZXJzID0gewogICAgICAgICJDb250ZW50LVR5cGUi
  >> "!B64TMP!" echo OiAibXVsdGlwYXJ0L2Zvcm0tZGF0YTsgYm91bmRhcnk9IiArIGJvdW5kYXJ5LAogICAgfQogICAg
  >> "!B64TMP!" echo a2V5ID0gX3NldHRpbmcoIkZJUkVDUkFXTF9BUElfS0VZIikKICAgIGlmIGtleToKICAgICAgICBo
  >> "!B64TMP!" echo ZWFkZXJzWyJBdXRob3JpemF0aW9uIl0gPSAiQmVhcmVyICIgKyBrZXkKCiAgICB0cnk6CiAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIF9yZXF1ZXN0KGVuZHBvaW50LCAiUE9TVCIsIGJvZHksIGhlYWRlcnMsIHRpbWVv
  >> "!B64TMP!" echo dXQpCiAgICBleGNlcHQgdXJsbGliLmVycm9yLkhUVFBFcnJvciBhcyBlOgogICAgICAgIHN0YXR1
  >> "!B64TMP!" echo cyA9IGUuY29kZQogICAgICAgIGRldGFpbCA9IF9yZWFkX2JvZHkoZSkKICAgICAgICByYWlzZSBG
  >> "!B64TMP!" echo Y0Vycm9yKCJIVFRQIHt9e317fSIuZm9ybWF0KAogICAgICAgICAgICBzdGF0dXMsICI6ICIgKyBk
  >> "!B64TMP!" echo ZXRhaWwgaWYgZGV0YWlsIGVsc2UgIiIpLAogICAgICAgICAgICBzdGF0dXM9c3RhdHVzLCBoaW50
  >> "!B64TMP!" echo PV9oaW50X2Zvcl9zdGF0dXMoc3RhdHVzKSkgZnJvbSBlCiAgICBleGNlcHQgRmNFcnJvcjoKICAg
  >> "!B64TMP!" echo ICAgICByYWlzZQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOiAgIyBjb25uZWN0aW9uIHByb2Js
  >> "!B64TMP!" echo ZW06IHN0YWNrIChwcm9iYWJseSkgZG93bgogICAgICAgIGlmIG5vdCBpc19sb2NhbCgpOgogICAg
  >> "!B64TMP!" echo ICAgICAgICByYWlzZSBGY0Vycm9yKAogICAgICAgICAgICAgICAgImNvdWxkIG5vdCByZWFjaCB7
  >> "!B64TMP!" echo fSAoe30pLiBDaGVjayB0aGUgVVJMIGFuZCB5b3VyIG5ldHdvcmssICIKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICJ0aGVuIHJldHJ5LiIuZm9ybWF0KGJhc2VfdXJsKCksIGUpKSBmcm9tIGUKICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChmIlN0YWNrIHVucmVhY2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5
  >> "!B64TMP!" echo IC4uLiIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIG9rLCBtZXNzYWdl
  >> "!B64TMP!" echo ID0gX3NlbGZoZWFsKCkKICAgICAgICBpZiBub3Qgb2s6CiAgICAgICAgICAgIHJhaXNlIEZjRXJy
  >> "!B64TMP!" echo b3IoInRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgY291bGQgbm90IGJlIHN0YXJ0ZWQ6ICIKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICArIG1lc3NhZ2UpIGZyb20gZQogICAgICAgIHRyeToKICAgICAg
  >> "!B64TMP!" echo ICAgICAgcmV0dXJuIF9yZXF1ZXN0KGVuZHBvaW50LCAiUE9TVCIsIGJvZHksIGhlYWRlcnMsIHRp
  >> "!B64TMP!" echo bWVvdXQpCiAgICAgICAgZXhjZXB0IHVybGxpYi5lcnJvci5IVFRQRXJyb3IgYXMgZTI6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHJhaXNlIEZjRXJyb3IoIkhUVFAge306IHt9Ii5mb3JtYXQoZTIuY29kZSwgX3JlYWRf
  >> "!B64TMP!" echo Ym9keShlMikpLAogICAgICAgICAgICAgICAgICAgICAgICAgIHN0YXR1cz1lMi5jb2RlLAogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgIGhpbnQ9X2hpbnRfZm9yX3N0YXR1cyhlMi5jb2RlKSkgZnJv
  >> "!B64TMP!" echo bSBlMgogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTI6CiAgICAgICAgICAgIHJhaXNlIEZj
  >> "!B64TMP!" echo RXJyb3IoInJlcXVlc3QgZmFpbGVkIGFmdGVyIHRoZSBzdGFjayB3YXMgc3RhcnRlZDogIgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICJ7fSIuZm9ybWF0KGUyKSkgZnJvbSBlMgo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\firecrawl_api.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_search.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_search.py" "!TARGET!\local-web-search\scripts\web_search.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1822793958.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggdGhlIHdlYiB2aWEgdGhlIGxvY2FsIFNl
  >> "!B64TMP!" echo YXJYTkcgaW5zdGFuY2UgYW5kIHByaW50IGNvbXBhY3QgcmVzdWx0cy4KClVzYWdlOgogICAgcHl0
  >> "!B64TMP!" echo aG9uIHdlYl9zZWFyY2gucHkgInlvdXIgcXVlcnkiIFstLWxpbWl0IDhdIFstLXRpbWUtcmFuZ2Ug
  >> "!B64TMP!" echo ZGF5fHdlZWt8bW9udGhdCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBbLS1jYXRl
  >> "!B64TMP!" echo Z29yaWVzIGl0LG5ld3MsZ2VuZXJhbF0KClNlbGYtaGVhbGluZzogaWYgdGhlIGxvY2FsLXNlYXJj
  >> "!B64TMP!" echo aCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0aGUKY29udGFpbmVycyBh
  >> "!B64TMP!" echo cmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1l
  >> "!B64TMP!" echo IGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCByZXRyaWVzIHRoZSBzZWFy
  >> "!B64TMP!" echo Y2ggb25jZS4gWW91IGRvIE5PVCBuZWVkCnRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCU
  >> "!B64TMP!" echo IGp1c3QgcnVuIHRoZSBzZWFyY2guCgpQcmludHMgdXAgdG8gYGxpbWl0YCByZXN1bHRzLCBlYWNo
  >> "!B64TMP!" echo IGFzOgogICAgTi4gPHRpdGxlPgogICAgICAgPHVybD4KICAgICAgIDxzbmlwcGV0PgoiIiIKaW1w
  >> "!B64TMP!" echo b3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzeXMKaW1wb3J0IHVybGxpYi5lcnJvcgppbXBvcnQg
  >> "!B64TMP!" echo dXJsbGliLnBhcnNlCmltcG9ydCB1cmxsaWIucmVxdWVzdAoKIyBEZWZhdWx0IHN0ZG91dC9zdGRl
  >> "!B64TMP!" echo cnIgdG8gVVRGLTggcmVnYXJkbGVzcyBvZiB0aGUgaG9zdCBsb2NhbGUvY29kZXBhZ2UKIyAoZS5n
  >> "!B64TMP!" echo LiBXaW5kb3dzIGNwMTI1MiksIHNvIHNlYXJjaCByZXN1bHRzIHdpdGggbm9uLUFTQ0lJIHRleHQg
  >> "!B64TMP!" echo bmV2ZXIgY3Jhc2gKIyB3aXRoIGEgVW5pY29kZUVuY29kZUVycm9yLiBTa2lwcGVkIGlmIFBZVEhP
  >> "!B64TMP!" echo TklPRU5DT0RJTkcgaXMgYWxyZWFkeSBzZXQg4oCUCiMgYW4gZXhwbGljaXQgb3ZlcnJpZGUgYWx3
  >> "!B64TMP!" echo YXlzIHdpbnMuCmlmICJQWVRIT05JT0VOQ09ESU5HIiBub3QgaW4gb3MuZW52aXJvbjoKICAgIGZv
  >> "!B64TMP!" echo ciBfc3RyZWFtIGluIChzeXMuc3Rkb3V0LCBzeXMuc3RkZXJyKToKICAgICAgICBpZiBoYXNhdHRy
  >> "!B64TMP!" echo KF9zdHJlYW0sICJyZWNvbmZpZ3VyZSIpOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBfc3RyZWFtLnJlY29uZmlndXJlKGVuY29kaW5nPSJ1dGYtOCIpCiAgICAgICAgICAgIGV4Y2Vw
  >> "!B64TMP!" echo dCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICBwYXNzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3Mu
  >> "!B64TMP!" echo cGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgY29uZmlnICAj
  >> "!B64TMP!" echo IHNpYmxpbmcgbW9kdWxlOiBpbnN0YWxsLWRpciBsb29rdXAgKyAuZW52LWRyaXZlbiBlbmRwb2lu
  >> "!B64TMP!" echo dHMKCiMgUG9ydCBjb21lcyBmcm9tIFNFQVJYTkdfUE9SVCBpbiB0aGUgaW5zdGFsbCBmb2xkZXIn
  >> "!B64TMP!" echo cyAuZW52IChkZWZhdWx0IDk5OTApLgpCQVNFID0gY29uZmlnLmVuZHBvaW50cyhjb25maWcuZmlu
  >> "!B64TMP!" echo ZF9pbnN0YWxsX2RpcigpKVsic2VhcnhuZyJdICsgIi9zZWFyY2giCgpUSU1FT1VUID0gMzAgICMg
  >> "!B64TMP!" echo c2Vjb25kcyBwZXIgSFRUUCBhdHRlbXB0CgoKZGVmIGZldGNoKHVybCk6CiAgICAiIiJHRVQgdGhl
  >> "!B64TMP!" echo IFNlYXJYTkcgSlNPTiBBUEkuIFJhaXNlcyBIVFRQRXJyb3Igd2hlbiB0aGUgc2VydmljZSBhbnN3
  >> "!B64TMP!" echo ZXJlZAogICAgd2l0aCBhbiBlcnJvciBzdGF0dXMgKHNlcnZpY2UgaXMgVVApLCBVUkxFcnJvci1m
  >> "!B64TMP!" echo YW1pbHkgb24gY29ubmVjdGlvbgogICAgcHJvYmxlbXMgKHNlcnZpY2UgaXMgRE9XTikuIiIiCiAg
  >> "!B64TMP!" echo ICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KHVybCkKICAgIHdpdGggdXJsbGliLnJlcXVl
  >> "!B64TMP!" echo c3QudXJsb3BlbihyZXEsIHRpbWVvdXQ9VElNRU9VVCkgYXMgcjoKICAgICAgICByZXR1cm4ganNv
  >> "!B64TMP!" echo bi5sb2FkKHIpCgoKZGVmIHNlbGZoZWFsKCk6CiAgICAiIiJTdGFydCB0aGUgRG9ja2VyIGVuZ2lu
  >> "!B64TMP!" echo ZSArIHRoZSBjb250YWluZXJzIGlmIHRoZXkgYXJlIGRvd24gKHRoZSBzYW1lCiAgICBsb2dpYyBh
  >> "!B64TMP!" echo cyBlbnN1cmVfc3RhY2sucHkpLiBJbXBvcnQgaXMgZGVmZXJyZWQgc28gdGhlIGZhc3QgcGF0aCAo
  >> "!B64TMP!" echo c3RhY2sKICAgIGFscmVhZHkgdXApIHBheXMgbm90aGluZy4gUmV0dXJucyAob2ssIG1lc3NhZ2Up
  >> "!B64TMP!" echo LiIiIgogICAgdHJ5OgogICAgICAgIGltcG9ydCBlbnN1cmVfc3RhY2sKICAgICAgICBvaywgbWVz
  >> "!B64TMP!" echo c2FnZSwgX2NvZGUgPSBlbnN1cmVfc3RhY2suZW5zdXJlX3JlYWR5KCkKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo b2ssIG1lc3NhZ2UKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTogICMgdW5leHBlY3RlZCBzZWxm
  >> "!B64TMP!" echo LWhlYWwgZmFpbHVyZTogZGVncmFkZSBncmFjZWZ1bGx5CiAgICAgICAgcmV0dXJuIEZhbHNlLCAi
  >> "!B64TMP!" echo c2VsZi1oZWFsIGZhaWxlZCB1bmV4cGVjdGVkbHk6IHt9Ii5mb3JtYXQoZSkKCgpkZWYgbWFpbigp
  >> "!B64TMP!" echo IC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGxpbWl0LCB0aW1lX3JhbmdlLCBj
  >> "!B64TMP!" echo YXRlZ29yaWVzID0gOCwgTm9uZSwgTm9uZQogICAgcXVlcnlfcGFydHMgPSBbXQogICAgaSA9IDAK
  >> "!B64TMP!" echo ICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAgICBpZiBh
  >> "!B64TMP!" echo ID09ICItLWxpbWl0IjoKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIGxpbWl0ID0gaW50
  >> "!B64TMP!" echo KGFyZ3NbaV0pCiAgICAgICAgZWxpZiBhID09ICItLXRpbWUtcmFuZ2UiOgogICAgICAgICAgICBp
  >> "!B64TMP!" echo ICs9IDEKICAgICAgICAgICAgdGltZV9yYW5nZSA9IGFyZ3NbaV0KICAgICAgICBlbGlmIGEgPT0g
  >> "!B64TMP!" echo Ii0tY2F0ZWdvcmllcyI6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICBjYXRlZ29yaWVz
  >> "!B64TMP!" echo ID0gYXJnc1tpXQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgICAgICBw
  >> "!B64TMP!" echo cmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAg
  >> "!B64TMP!" echo IHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcXVlcnlfcGFydHMuYXBwZW5kKGEp
  >> "!B64TMP!" echo CiAgICAgICAgaSArPSAxCiAgICBxdWVyeSA9ICIgIi5qb2luKHF1ZXJ5X3BhcnRzKS5zdHJpcCgp
  >> "!B64TMP!" echo CiAgICBpZiBub3QgcXVlcnk6CiAgICAgICAgcHJpbnQoJ3VzYWdlOiB3ZWJfc2VhcmNoLnB5ICJx
  >> "!B64TMP!" echo dWVyeSIgWy0tbGltaXQgTl0gWy0tdGltZS1yYW5nZSBSXSBbLS1jYXRlZ29yaWVzIENdJywgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCgogICAgcGFyYW1zID0geyJxIjogcXVlcnks
  >> "!B64TMP!" echo ICJmb3JtYXQiOiAianNvbiIsICJsYW5ndWFnZSI6ICJlbiJ9CiAgICBpZiB0aW1lX3JhbmdlOgog
  >> "!B64TMP!" echo ICAgICAgIHBhcmFtc1sidGltZV9yYW5nZSJdID0gdGltZV9yYW5nZQogICAgaWYgY2F0ZWdvcmll
  >> "!B64TMP!" echo czoKICAgICAgICBwYXJhbXNbImNhdGVnb3JpZXMiXSA9IGNhdGVnb3JpZXMKICAgIHVybCA9IEJB
  >> "!B64TMP!" echo U0UgKyAiPyIgKyB1cmxsaWIucGFyc2UudXJsZW5jb2RlKHBhcmFtcykKCiAgICBkYXRhID0gTm9u
  >> "!B64TMP!" echo ZQogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmZXRjaCh1cmwpCiAgICBleGNlcHQgdXJsbGliLmVy
  >> "!B64TMP!" echo cm9yLkhUVFBFcnJvciBhcyBlOgogICAgICAgICMgVGhlIHNlcnZpY2UgQU5TV0VSRUQgKGV2ZW4g
  >> "!B64TMP!" echo d2l0aCBhbiBlcnJvciBzdGF0dXMpIC0+IGl0IGlzIHVwOwogICAgICAgICMgc3RhcnRpbmcgY29u
  >> "!B64TMP!" echo dGFpbmVycyB3b3VsZCBub3QgaGVscC4KICAgICAgICBwcmludChmIlNFQVJDSCBGQUlMRUQ6IHtl
  >> "!B64TMP!" echo fSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludCgiU2VhclhORyBhbnN3ZXJlZCB3aXRo
  >> "!B64TMP!" echo IGFuIGVycm9yIHN0YXR1cyAodGhlIHN0YWNrIGlzIHJ1bm5pbmcpLiAiCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IlJldHJ5IG9uY2Ugd2l0aCBhIGRpZmZlcmVudCBxdWVyeSwgb3IgaW5zcGVjdCB0aGUgc3RhY2sg
  >> "!B64TMP!" echo d2l0aDogIgogICAgICAgICAgICAgICJjZCA8aW5zdGFsbCBmb2xkZXI+ICYmIGRvY2tlciBjb21w
  >> "!B64TMP!" echo b3NlIGxvZ3MgLS10YWlsIDUwIHNlYXJ4bmciLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgICAgICByZXR1cm4gMQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICMg
  >> "!B64TMP!" echo Q29ubmVjdGlvbiBlcnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJseSkgZG93biAtPiBzZWxmLWhl
  >> "!B64TMP!" echo YWwgb25jZSwKICAgICAgICAjIHRoZW4gcmV0cnkgdGhlIHNlYXJjaC4KICAgICAgICBwcmludChm
  >> "!B64TMP!" echo IlN0YWNrIHVucmVhY2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IC4u
  >> "!B64TMP!" echo LiIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIG9rLCBtZXNzYWdlID0g
  >> "!B64TMP!" echo c2VsZmhlYWwoKQogICAgICAgIGlmIG5vdCBvazoKICAgICAgICAgICAgcHJpbnQobWVzc2FnZSwg
  >> "!B64TMP!" echo ZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBwcmludCgiU0VBUkNIIEZBSUxFRDogdGhlIGxv
  >> "!B64TMP!" echo Y2FsLXNlYXJjaCBzdGFjayBjb3VsZCBub3QgYmUgc3RhcnRlZC4gIgogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiUmVzb2x2ZSB0aGUgc3RhY2sgKG9yIGFzayB0aGUgdXNlciB0byBzdGFydCBEb2NrZXIgRGVz
  >> "!B64TMP!" echo a3RvcCkgIgogICAgICAgICAgICAgICAgICAiYW5kIHJldHJ5IOKAlCBkbyBOT1QgZmFsbCBiYWNr
  >> "!B64TMP!" echo IHRvIG90aGVyIHdlYiB0b29scyB1bmxlc3MgdGhlICIKICAgICAgICAgICAgICAgICAgInVzZXIg
  >> "!B64TMP!" echo YXNrcy4iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAxCiAgICAgICAgdHJ5
  >> "!B64TMP!" echo OgogICAgICAgICAgICBkYXRhID0gZmV0Y2godXJsKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24g
  >> "!B64TMP!" echo YXMgZTI6CiAgICAgICAgICAgIHByaW50KGYiU0VBUkNIIEZBSUxFRCBhZnRlciB0aGUgc3RhY2sg
  >> "!B64TMP!" echo d2FzIHN0YXJ0ZWQ6IHtlMn0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAx
  >> "!B64TMP!" echo CgogICAgcmVzdWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIiwgW10pWzpsaW1pdF0KICAgIGlmIG5v
  >> "!B64TMP!" echo dCByZXN1bHRzOgogICAgICAgIHByaW50KCIobm8gcmVzdWx0cykiKQogICAgICAgIHJldHVybiAw
  >> "!B64TMP!" echo CiAgICBmb3IgbiwgaGl0IGluIGVudW1lcmF0ZShyZXN1bHRzLCAxKToKICAgICAgICB0aXRsZSA9
  >> "!B64TMP!" echo IChoaXQuZ2V0KCJ0aXRsZSIpIG9yICIiKS5zdHJpcCgpCiAgICAgICAgcmVzdWx0X3VybCA9IGhp
  >> "!B64TMP!" echo dC5nZXQoInVybCIpIG9yICIiCiAgICAgICAgY29udGVudCA9IChoaXQuZ2V0KCJjb250ZW50Iikg
  >> "!B64TMP!" echo b3IgIiIpLnN0cmlwKCkucmVwbGFjZSgiXG4iLCAiICIpCiAgICAgICAgaWYgbGVuKGNvbnRlbnQp
  >> "!B64TMP!" echo ID4gMzAwOgogICAgICAgICAgICBjb250ZW50ID0gY29udGVudFs6MzAwXSArICLigKYiCiAgICAg
  >> "!B64TMP!" echo ICAgcHJpbnQoZiJ7bn0uIHt0aXRsZX0iKQogICAgICAgIHByaW50KGYiICAge3Jlc3VsdF91cmx9
  >> "!B64TMP!" echo IikKICAgICAgICBpZiBjb250ZW50OgogICAgICAgICAgICBwcmludChmIiAgIHtjb250ZW50fSIp
  >> "!B64TMP!" echo CiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdCht
  >> "!B64TMP!" echo YWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_search.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_scrape.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_scrape.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_scrape.py" "!TARGET!\local-web-search\scripts\web_scrape.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_scrape.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_scrape.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2895407752.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZWFkIGEgd2ViIHBhZ2UgYXMgY2xlYW4gTWFya2Rv
  >> "!B64TMP!" echo d24gdmlhIHRoZSBsb2NhbCBGaXJlY3Jhd2wgaW5zdGFuY2UuCgpVc2FnZToKICAgIHB5dGhvbiB3
  >> "!B64TMP!" echo ZWJfc2NyYXBlLnB5IDx1cmw+IFstLW1heC1jaGFycyAyMDAwMF0KClNlbGYtaGVhbGluZzogaWYg
  >> "!B64TMP!" echo dGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0
  >> "!B64TMP!" echo aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRz
  >> "!B64TMP!" echo IHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCBy
  >> "!B64TMP!" echo ZXRyaWVzIHRoZSBzY3JhcGUgb25jZS4gWW91IGRvIE5PVCBuZWVkCnRvIHJ1biBlbnN1cmVfc3Rh
  >> "!B64TMP!" echo Y2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JhcGUuCgpQcmludHMgdGhlIHBhZ2UncyBN
  >> "!B64TMP!" echo YXJrZG93biB0byBzdGRvdXQsIHRydW5jYXRlZCBhdCAtLW1heC1jaGFycy4KIiIiCmltcG9ydCBq
  >> "!B64TMP!" echo c29uCmltcG9ydCBvcwppbXBvcnQgc3lzCmltcG9ydCB1cmxsaWIuZXJyb3IKaW1wb3J0IHVybGxp
  >> "!B64TMP!" echo Yi5yZXF1ZXN0CgojIERlZmF1bHQgc3Rkb3V0L3N0ZGVyciB0byBVVEYtOCByZWdhcmRsZXNzIG9m
  >> "!B64TMP!" echo IHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQojIChlLmcuIFdpbmRvd3MgY3AxMjUyKSwgc28gc2Ny
  >> "!B64TMP!" echo YXBlZCBwYWdlIGNvbnRlbnQgd2l0aCBub24tQVNDSUkgdGV4dCBuZXZlcgojIGNyYXNoZXMgd2l0
  >> "!B64TMP!" echo aCBhIFVuaWNvZGVFbmNvZGVFcnJvci4gU2tpcHBlZCBpZiBQWVRIT05JT0VOQ09ESU5HIGlzIGFs
  >> "!B64TMP!" echo cmVhZHkKIyBzZXQg4oCUIGFuIGV4cGxpY2l0IG92ZXJyaWRlIGFsd2F5cyB3aW5zLgppZiAiUFlU
  >> "!B64TMP!" echo SE9OSU9FTkNPRElORyIgbm90IGluIG9zLmVudmlyb246CiAgICBmb3IgX3N0cmVhbSBpbiAoc3lz
  >> "!B64TMP!" echo LnN0ZG91dCwgc3lzLnN0ZGVycik6CiAgICAgICAgaWYgaGFzYXR0cihfc3RyZWFtLCAicmVjb25m
  >> "!B64TMP!" echo aWd1cmUiKToKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgX3N0cmVhbS5yZWNvbmZp
  >> "!B64TMP!" echo Z3VyZShlbmNvZGluZz0idXRmLTgiKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgcGFzcwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5w
  >> "!B64TMP!" echo YXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGNvbmZpZyAgIyBzaWJsaW5nIG1vZHVsZTog
  >> "!B64TMP!" echo aW5zdGFsbC1kaXIgbG9va3VwICsgLmVudi1kcml2ZW4gZW5kcG9pbnRzCgojIFBvcnQgY29tZXMg
  >> "!B64TMP!" echo ZnJvbSBGSVJFQ1JBV0xfUE9SVCBpbiB0aGUgaW5zdGFsbCBmb2xkZXIncyAuZW52IChkZWZhdWx0
  >> "!B64TMP!" echo IDk5OTEpLgpFTkRQT0lOVCA9IGNvbmZpZy5lbmRwb2ludHMoY29uZmlnLmZpbmRfaW5zdGFsbF9k
  >> "!B64TMP!" echo aXIoKSlbImZpcmVjcmF3bCJdICsgIi92MS9zY3JhcGUiCgpUSU1FT1VUID0gOTAgICMgc2Vjb25k
  >> "!B64TMP!" echo cyBwZXIgSFRUUCBhdHRlbXB0CgoKZGVmIGZldGNoKHVybCk6CiAgICAiIiJQT1NUIHRoZSBzY3Jh
  >> "!B64TMP!" echo cGUgcmVxdWVzdC4gUmFpc2VzIEhUVFBFcnJvciB3aGVuIHRoZSBzZXJ2aWNlIGFuc3dlcmVkCiAg
  >> "!B64TMP!" echo ICB3aXRoIGFuIGVycm9yIHN0YXR1cyAoc2VydmljZSBpcyBVUCksIFVSTEVycm9yLWZhbWlseSBv
  >> "!B64TMP!" echo biBjb25uZWN0aW9uCiAgICBwcm9ibGVtcyAoc2VydmljZSBpcyBET1dOKS4iIiIKICAgIGJvZHkg
  >> "!B64TMP!" echo PSBqc29uLmR1bXBzKHsidXJsIjogdXJsLCAiZm9ybWF0cyI6IFsibWFya2Rvd24iXX0pLmVuY29k
  >> "!B64TMP!" echo ZSgpCiAgICByZXEgPSB1cmxsaWIucmVxdWVzdC5SZXF1ZXN0KAogICAgICAgIEVORFBPSU5ULAog
  >> "!B64TMP!" echo ICAgICAgIGRhdGE9Ym9keSwKICAgICAgICBoZWFkZXJzPXsiQ29udGVudC1UeXBlIjogImFwcGxp
  >> "!B64TMP!" echo Y2F0aW9uL2pzb24ifSwKICAgICAgICBtZXRob2Q9IlBPU1QiLAogICAgKQogICAgd2l0aCB1cmxs
  >> "!B64TMP!" echo aWIucmVxdWVzdC51cmxvcGVuKHJlcSwgdGltZW91dD1USU1FT1VUKSBhcyByOgogICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiBqc29uLmxvYWQocikKCgpkZWYgc2VsZmhlYWwoKToKICAgICIiIlN0YXJ0IHRoZSBEb2Nr
  >> "!B64TMP!" echo ZXIgZW5naW5lICsgdGhlIGNvbnRhaW5lcnMgaWYgdGhleSBhcmUgZG93biAodGhlIHNhbWUKICAg
  >> "!B64TMP!" echo IGxvZ2ljIGFzIGVuc3VyZV9zdGFjay5weSkuIEltcG9ydCBpcyBkZWZlcnJlZCBzbyB0aGUgZmFz
  >> "!B64TMP!" echo dCBwYXRoIChzdGFjawogICAgYWxyZWFkeSB1cCkgcGF5cyBub3RoaW5nLiBSZXR1cm5zIChvaywg
  >> "!B64TMP!" echo bWVzc2FnZSkuIiIiCiAgICB0cnk6CiAgICAgICAgaW1wb3J0IGVuc3VyZV9zdGFjawogICAgICAg
  >> "!B64TMP!" echo IG9rLCBtZXNzYWdlLCBfY29kZSA9IGVuc3VyZV9zdGFjay5lbnN1cmVfcmVhZHkoKQogICAgICAg
  >> "!B64TMP!" echo IHJldHVybiBvaywgbWVzc2FnZQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOiAgIyB1bmV4cGVj
  >> "!B64TMP!" echo dGVkIHNlbGYtaGVhbCBmYWlsdXJlOiBkZWdyYWRlIGdyYWNlZnVsbHkKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo RmFsc2UsICJzZWxmLWhlYWwgZmFpbGVkIHVuZXhwZWN0ZWRseToge30iLmZvcm1hdChlKQoKCmRl
  >> "!B64TMP!" echo ZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mg
  >> "!B64TMP!" echo b3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX3Nj
  >> "!B64TMP!" echo cmFwZS5weSA8dXJsPiBbLS1tYXgtY2hhcnMgTl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIDIKICAgIHVybCA9IGFyZ3NbMF0KICAgIG1heF9jaGFycyA9IDIwMDAwCiAgICBpID0g
  >> "!B64TMP!" echo MQogICAgd2hpbGUgaSA8IGxlbihhcmdzKToKICAgICAgICBpZiBhcmdzW2ldID09ICItLW1heC1j
  >> "!B64TMP!" echo aGFycyIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQo
  >> "!B64TMP!" echo YXJnc1tpICsgMV0pCiAgICAgICAgICAgIGkgKz0gMgogICAgICAgIGVsc2U6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IGkgKz0gMQoKICAgIGRhdGEgPSBOb25lCiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZldGNoKHVy
  >> "!B64TMP!" echo bCkKICAgIGV4Y2VwdCB1cmxsaWIuZXJyb3IuSFRUUEVycm9yIGFzIGU6CiAgICAgICAgIyBUaGUg
  >> "!B64TMP!" echo c2VydmljZSBBTlNXRVJFRCAoZXZlbiB3aXRoIGFuIGVycm9yIHN0YXR1cykgLT4gaXQgaXMgdXA7
  >> "!B64TMP!" echo CiAgICAgICAgIyBzdGFydGluZyBjb250YWluZXJzIHdvdWxkIG5vdCBoZWxwLgogICAgICAgIHBy
  >> "!B64TMP!" echo aW50KGYiU0NSQVBFIEZBSUxFRCBmb3Ige3VybH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICBwcmludCgiRmlyZWNyYXdsIGFuc3dlcmVkIHdpdGggYW4gZXJyb3Igc3RhdHVzICh0aGUg
  >> "!B64TMP!" echo c3RhY2sgaXMgcnVubmluZykuICIKICAgICAgICAgICAgICAiUmV0cnkgb25jZSB3aXRoIGEgZGlm
  >> "!B64TMP!" echo ZmVyZW50IHJlc3VsdCBVUkwsIG9yIGluc3BlY3QgdGhlIHN0YWNrICIKICAgICAgICAgICAgICAi
  >> "!B64TMP!" echo d2l0aDogY2QgPGluc3RhbGwgZm9sZGVyPiAmJiBkb2NrZXIgY29tcG9zZSBsb2dzIC0tdGFpbCA1
  >> "!B64TMP!" echo MCAiCiAgICAgICAgICAgICAgImZpcmVjcmF3bCIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gMQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBlOgogICAgICAgICMgQ29ubmVjdGlvbiBl
  >> "!B64TMP!" echo cnJvcjogdGhlIHN0YWNrIGlzIChwcm9iYWJseSkgZG93biAtPiBzZWxmLWhlYWwgb25jZSwKICAg
  >> "!B64TMP!" echo ICAgICAjIHRoZW4gcmV0cnkgdGhlIHNjcmFwZS4KICAgICAgICBwcmludChmIlN0YWNrIHVucmVh
  >> "!B64TMP!" echo Y2hhYmxlICh7ZX0pIOKAlCBzdGFydGluZyBpdCBhdXRvbWF0aWNhbGx5IC4uLiIsCiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIG9rLCBtZXNzYWdlID0gc2VsZmhlYWwoKQog
  >> "!B64TMP!" echo ICAgICAgIGlmIG5vdCBvazoKICAgICAgICAgICAgcHJpbnQobWVzc2FnZSwgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgICAgICBwcmludCgiU0NSQVBFIEZBSUxFRCBmb3Ige306IHRoZSBsb2NhbC1z
  >> "!B64TMP!" echo ZWFyY2ggc3RhY2sgY291bGQgbm90IGJlICIKICAgICAgICAgICAgICAgICAgInN0YXJ0ZWQuIFJl
  >> "!B64TMP!" echo c29sdmUgdGhlIHN0YWNrIChvciBhc2sgdGhlIHVzZXIgdG8gc3RhcnQgRG9ja2VyICIKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIkRlc2t0b3ApIGFuZCByZXRyeSDigJQgZG8gTk9UIGZhbGwgYmFjayB0byBv
  >> "!B64TMP!" echo dGhlciB3ZWIgdG9vbHMgIgogICAgICAgICAgICAgICAgICAidW5sZXNzIHRoZSB1c2VyIGFza3Mu
  >> "!B64TMP!" echo Ii5mb3JtYXQodXJsKSwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMQogICAg
  >> "!B64TMP!" echo ICAgIHRyeToKICAgICAgICAgICAgZGF0YSA9IGZldGNoKHVybCkKICAgICAgICBleGNlcHQgRXhj
  >> "!B64TMP!" echo ZXB0aW9uIGFzIGUyOgogICAgICAgICAgICBwcmludChmIlNDUkFQRSBGQUlMRUQgZm9yIHt1cmx9
  >> "!B64TMP!" echo IGFmdGVyIHRoZSBzdGFjayB3YXMgc3RhcnRlZDoge2UyfSIsCiAgICAgICAgICAgICAgICAgIGZp
  >> "!B64TMP!" echo bGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDEKCiAgICBwYXlsb2FkID0gZGF0YS5n
  >> "!B64TMP!" echo ZXQoImRhdGEiKSBvciB7fQogICAgbWFya2Rvd24gPSBwYXlsb2FkLmdldCgibWFya2Rvd24iKSBv
  >> "!B64TMP!" echo ciAiIiBpZiBpc2luc3RhbmNlKHBheWxvYWQsIGRpY3QpIGVsc2UgIiIKICAgIGlmIG5vdCBtYXJr
  >> "!B64TMP!" echo ZG93bjoKICAgICAgICBwcmludCgiU0NSQVBFIFJFVFVSTkVEIE5PIE1BUktET1dOIGZvciIsIHVy
  >> "!B64TMP!" echo bCwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHByaW50KGpzb24uZHVtcHMoZGF0YSlbOjgwMF0s
  >> "!B64TMP!" echo IGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGxlbihtYXJrZG93bikg
  >> "!B64TMP!" echo PiBtYXhfY2hhcnM6CiAgICAgICAgbWFya2Rvd24gPSBtYXJrZG93bls6bWF4X2NoYXJzXSArIGYi
  >> "!B64TMP!" echo XG5cblsuLi4gdHJ1bmNhdGVkIGF0IHttYXhfY2hhcnN9IGNoYXJzIC4uLl0iCiAgICBwcmludCht
  >> "!B64TMP!" echo YXJrZG93bikKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5
  >> "!B64TMP!" echo cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_scrape.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_extract.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_extract.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_extract.py" "!TARGET!\local-web-search\scripts\web_extract.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_extract.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_extract.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3639765009.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJMTE0gZXh0cmFjdGlvbiBmcm9tIG9uZSBvciBtb3Jl
  >> "!B64TMP!" echo IFVSTHMgdmlhIHRoZSBsb2NhbCBGaXJlY3Jhd2wgL3YxL2V4dHJhY3QKZW5kcG9pbnQuCgpSdW5z
  >> "!B64TMP!" echo IG9uIHRoZSBPcGVuQUktY29tcGF0aWJsZSBMTE0gY29ubmVjdGVkIGluIHRoZSBpbnN0YWxsZXIK
  >> "!B64TMP!" echo KE9QRU5BSV9CQVNFX1VSTCAvIE9QRU5BSV9BUElfS0VZIC8gTU9ERUxfTkFNRSBpbiB0aGUgaW5z
  >> "!B64TMP!" echo dGFsbCBmb2xkZXIncwouZW52KTsgdGhlIGVuZHBvaW50IG1heSBiZSBsb2NhbCBvciByZW1vdGUu
  >> "!B64TMP!" echo IFdpdGhvdXQgYSBjb25maWd1cmVkIExMTSB0aGUKZW5kcG9pbnQgZmFpbHMgd2l0aCBhICJtb2Rl
  >> "!B64TMP!" echo bCBub3QgY29uZmlndXJlZCIgZXJyb3IsIHdoaWNoIGlzIGV4cGVjdGVkIGFuZApub3QgYSBzdGFj
  >> "!B64TMP!" echo ayBmYWlsdXJlLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2V4dHJhY3QucHkgPHVybD4gW3VybCAu
  >> "!B64TMP!" echo Li5dIC0tcHJvbXB0ICJ3aGF0IHRvIGV4dHJhY3QiIFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlm
  >> "!B64TMP!" echo IHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IK
  >> "!B64TMP!" echo dGhlIGNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0
  >> "!B64TMP!" echo cyB0aGVtICh0aGUgc2FtZQpsb2dpYyBhcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQg
  >> "!B64TMP!" echo cmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbgpmYWlsdXJlcyBzZWxmLWhlYWwgb25jZTsg
  >> "!B64TMP!" echo dHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQKYmFja29m
  >> "!B64TMP!" echo Zi4gWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3Qg
  >> "!B64TMP!" echo cnVuIHRoZSBzY3JpcHQuCgpQcmludHMgdGhlIGV4dHJhY3RlZCByZXN1bHQgKHRoZSBgZGF0YWAg
  >> "!B64TMP!" echo ZmllbGQgb2YgdGhlIHJlc3BvbnNlKS4gYC0tanNvbmAKcHJpbnRzIHRoZSBmdWxsIHJhdyBBUEkg
  >> "!B64TMP!" echo cmVzcG9uc2UgaW5zdGVhZC4KRXhpdCBjb2RlczogMCBzdWNjZXNzLCAxIHRvb2wgZmFpbHVyZSwg
  >> "!B64TMP!" echo MiB1c2FnZSBlcnJvci4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMu
  >> "!B64TMP!" echo cGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykp
  >> "!B64TMP!" echo KQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBj
  >> "!B64TMP!" echo bGllbnQgKyBzZWxmLWhlYWwKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJn
  >> "!B64TMP!" echo dlsxOl0KICAgIHVybHMgPSBbXQogICAgcHJvbXB0ID0gTm9uZQogICAgYXNfanNvbiA9IEZhbHNl
  >> "!B64TMP!" echo CiAgICBpID0gMAogICAgd2hpbGUgaSA8IGxlbihhcmdzKToKICAgICAgICBhID0gYXJnc1tpXQog
  >> "!B64TMP!" echo ICAgICAgIGlmIGEgPT0gIi0tcHJvbXB0IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGkgKz0gMQogICAgICAgICAgICBwcm9tcHQgPSBhcmdzW2ldCiAgICAgICAgZWxpZiBhID09
  >> "!B64TMP!" echo ICItLWpzb24iOgogICAgICAgICAgICBhc19qc29uID0gVHJ1ZQogICAgICAgIGVsaWYgYS5zdGFy
  >> "!B64TMP!" echo dHN3aXRoKCItLSIpOgogICAgICAgICAgICBwcmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAg
  >> "!B64TMP!" echo ICAgICAgdXJscy5hcHBlbmQoYSkKICAgICAgICBpICs9IDEKCiAgICBpZiBub3QgdXJscyBvciBu
  >> "!B64TMP!" echo b3QgcHJvbXB0OgogICAgICAgIHByaW50KCd1c2FnZTogd2ViX2V4dHJhY3QucHkgPHVybD4gW3Vy
  >> "!B64TMP!" echo bCAuLi5dIC0tcHJvbXB0ICJ3aGF0IHRvIGV4dHJhY3QiIFstLWpzb25dJywKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKCiAgICB0cnk6CiAgICAgICAgZGF0
  >> "!B64TMP!" echo YSA9IGZjLmNhbGwoIi92MS9leHRyYWN0IiwgbWV0aG9kPSJQT1NUIiwKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBib2R5PXsidXJscyI6IHVybHMsICJwcm9tcHQiOiBwcm9tcHR9KQogICAgZXhjZXB0
  >> "!B64TMP!" echo IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIkVYVFJBQ1QgRkFJTEVEIGZvciB7Jywg
  >> "!B64TMP!" echo Jy5qb2luKHVybHMpfToge2V9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIGlmIGUuaGludDoK
  >> "!B64TMP!" echo ICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IDEKCiAgICBpZiBub3QgZGF0YS5nZXQoInN1Y2Nlc3MiLCBUcnVlKSBhbmQgbm90IGRhdGEuZ2V0
  >> "!B64TMP!" echo KCJkYXRhIik6CiAgICAgICAgcHJpbnQoIkVYVFJBQ1QgRkFJTEVEIGZvciB7fTogbm8gZGF0YSBy
  >> "!B64TMP!" echo ZXR1cm5lZC4gUmVzcG9uc2U6ICIKICAgICAgICAgICAgICAuZm9ybWF0KCIsICIuam9pbih1cmxz
  >> "!B64TMP!" echo KSksIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpWzo4MDBd
  >> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAg
  >> "!B64TMP!" echo ICAgIHByaW50KGpzb24uZHVtcHMoZGF0YSkpCiAgICBlbHNlOgogICAgICAgIHByaW50KGpzb24u
  >> "!B64TMP!" echo ZHVtcHMoZGF0YS5nZXQoImRhdGEiKSwgaW5kZW50PTIsIGVuc3VyZV9hc2NpaT1GYWxzZSkpCiAg
  >> "!B64TMP!" echo ICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWlu
  >> "!B64TMP!" echo KCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_extract.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_youtube_transcript.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_youtube_transcript.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_youtube_transcript.py" "!TARGET!\local-web-search\scripts\web_youtube_transcript.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_youtube_transcript.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_youtube_transcript.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1252984784.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJGZXRjaCBhIFlvdVR1YmUgdmlkZW8ncyB0cmFuc2Ny
  >> "!B64TMP!" echo aXB0IGFuZCBwcmludCBpdCBhcyBgW01NOlNTXSB0ZXh0YCBsaW5lcy4KClVzYWdlOgogICAgcHl0
  >> "!B64TMP!" echo aG9uIHdlYl95b3V0dWJlX3RyYW5zY3JpcHQucHkgPHZpZGVvX2lkIHwgeW91dHViZSB1cmw+IFst
  >> "!B64TMP!" echo LWxhbmcgZW4sZGVdCgpXaHkgeXQtZGxwOiBZb3VUdWJlIG5vdyBwcm90ZWN0cyB0aGUgY2FwdGlv
  >> "!B64TMP!" echo biB0cmFja3Mgb2YgYSBncm93aW5nIHNoYXJlIG9mCnZpZGVvcyB3aXRoIGEgIlBPIHRva2VuIiAo
  >> "!B64TMP!" echo dGhlIHRyYWNrIFVSTCBjYXJyaWVzIGBleHA9eHBlYCk7IGEgcGxhaW4gcmVxdWVzdApmb3Igc3Vj
  >> "!B64TMP!" echo aCBhIHRyYWNrIGdldHMgYW4gRU1QVFkgYW5zd2VyLiBgeW91dHViZS10cmFuc2NyaXB0LWFwaWAg
  >> "!B64TMP!" echo Y2Fubm90IHByb2R1Y2UKdGhhdCB0b2tlbiwgeXQtZGxwIGNhbi4gU28gdGhpcyBzY3JpcHQgdXNl
  >> "!B64TMP!" echo cyB5dC1kbHAsIHdoaWNoIG5lZWRzCgogICAgcGlwIGluc3RhbGwgLVUgInl0LWRscFtkZWZhdWx0
  >> "!B64TMP!" echo XSIgICAgICAgICMgaW5jbHVkZXMgeXQtZGxwLWVqcwogICAgKyBhIEphdmFTY3JpcHQgcnVudGlt
  >> "!B64TMP!" echo ZSBvbiBQQVRIOiBEZW5vLCBvciBOb2RlLmpzIDIyKyAoQnVuIC8gUXVpY2tKUyBhbHNvIHdvcmsp
  >> "!B64TMP!" echo CgpJZiB5dC1kbHAgaXMgbm90IGluc3RhbGxlZCAob3IgZmFpbHMpIGl0IGZhbGxzIGJhY2sgdG8g
  >> "!B64TMP!" echo dGhlIG9sZGVyCmB5b3V0dWJlLXRyYW5zY3JpcHQtYXBpYCBwYWNrYWdlLCB3aGljaCBzdGlsbCB3
  >> "!B64TMP!" echo b3JrcyBmb3IgdmlkZW9zIHRoYXQgYXJlIG5vdApiZWhpbmQgdGhlIHRva2VuIHlldC4KCkV4aXQg
  >> "!B64TMP!" echo c3RhdHVzOiAwID0gdHJhbnNjcmlwdCBwcmludGVkLCAxID0gZmFpbGVkIChyZWFzb24gb24gc3Rk
  >> "!B64TMP!" echo ZXJyKSwgMiA9IHVzYWdlLgoiIiIKaW1wb3J0IGdsb2IKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmlt
  >> "!B64TMP!" echo cG9ydCByZQppbXBvcnQgc2h1dGlsCmltcG9ydCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKaW1wb3J0
  >> "!B64TMP!" echo IHRlbXBmaWxlCgojIERlZmF1bHQgc3Rkb3V0L3N0ZGVyciB0byBVVEYtOCByZWdhcmRsZXNzIG9m
  >> "!B64TMP!" echo IHRoZSBob3N0IGxvY2FsZS9jb2RlcGFnZQojIChlLmcuIFdpbmRvd3MgY3AxMjUyKSwgc28gdHJh
  >> "!B64TMP!" echo bnNjcmlwdHMgd2l0aCBub24tQVNDSUkgdGV4dCBuZXZlciBjcmFzaAojIHdpdGggYSBVbmljb2Rl
  >> "!B64TMP!" echo RW5jb2RlRXJyb3IuIFNraXBwZWQgaWYgUFlUSE9OSU9FTkNPRElORyBpcyBhbHJlYWR5IHNldCDi
  >> "!B64TMP!" echo gJQKIyBhbiBleHBsaWNpdCBvdmVycmlkZSBhbHdheXMgd2lucy4KaWYgIlBZVEhPTklPRU5DT0RJ
  >> "!B64TMP!" echo TkciIG5vdCBpbiBvcy5lbnZpcm9uOgogICAgZm9yIF9zdHJlYW0gaW4gKHN5cy5zdGRvdXQsIHN5
  >> "!B64TMP!" echo cy5zdGRlcnIpOgogICAgICAgIGlmIGhhc2F0dHIoX3N0cmVhbSwgInJlY29uZmlndXJlIik6CiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIF9zdHJlYW0ucmVjb25maWd1cmUoZW5jb2Rp
  >> "!B64TMP!" echo bmc9InV0Zi04IikKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IHBhc3MKClZJREVPX0lEID0gcmUuY29tcGlsZShyIl5bQS1aYS16MC05Xy1dezExfSQiKQpVUkxf
  >> "!B64TMP!" echo SUQgPSByZS5jb21waWxlKHIiKD86Wz8mXXY9fHlvdXR1XC5iZS98L3Nob3J0cy98L2VtYmVkL3wv
  >> "!B64TMP!" echo bGl2ZS98L3YvKShbQS1aYS16MC05Xy1dezExfSkiKQpMQU5HID0gcmUuY29tcGlsZShyIl5bQS1a
  >> "!B64TMP!" echo YS16XXsyLDN9KD86LVtBLVphLXowLTldezIsOH0pKiQiKQpZVERMUF9USU1FT1VUID0gMTgwICAj
  >> "!B64TMP!" echo IHNlY29uZHMKCgpjbGFzcyBUcmFuc2NyaXB0RXJyb3IoRXhjZXB0aW9uKToKICAgICIiIkEgZmFp
  >> "!B64TMP!" echo bHVyZSB3aG9zZSBtZXNzYWdlIGlzIGFscmVhZHkgd3JpdHRlbiBmb3IgdGhlIGVuZCB1c2VyLiIi
  >> "!B64TMP!" echo IgoKCmRlZiB2aWRlb19pZF9mcm9tKGFyZyk6CiAgICBhcmcgPSBhcmcuc3RyaXAoKQogICAgaWYg
  >> "!B64TMP!" echo VklERU9fSUQubWF0Y2goYXJnKToKICAgICAgICByZXR1cm4gYXJnCiAgICBtID0gVVJMX0lELnNl
  >> "!B64TMP!" echo YXJjaChhcmcpCiAgICByZXR1cm4gbS5ncm91cCgxKSBpZiBtIGVsc2UgTm9uZQoKCiMgLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tIHl0LWRscApkZWYgeXRkbHBfY29tbWFuZCgpOgogICAgIiIiSG93IHRvIHJ1biB5dC1k
  >> "!B64TMP!" echo bHAsIG9yIE5vbmUgd2hlbiBpdCBpcyBub3QgaW5zdGFsbGVkLiIiIgogICAgdHJ5OgogICAgICAg
  >> "!B64TMP!" echo IGltcG9ydCB5dF9kbHAgICMgbm9xYTogRjQwMQogICAgICAgIHJldHVybiBbc3lzLmV4ZWN1dGFi
  >> "!B64TMP!" echo bGUsICItbSIsICJ5dF9kbHAiXQogICAgZXhjZXB0IEltcG9ydEVycm9yOgogICAgICAgIHBhc3MK
  >> "!B64TMP!" echo ICAgIGV4ZSA9IHNodXRpbC53aGljaCgieXQtZGxwIikKICAgIHJldHVybiBbZXhlXSBpZiBleGUg
  >> "!B64TMP!" echo ZWxzZSBOb25lCgoKZGVmIGpzX3J1bnRpbWVfYXJncygpOgogICAgIiIiKGV4dHJhIHl0LWRscCBh
  >> "!B64TMP!" echo cmdzLCBhIHJ1bnRpbWUgd2FzIGZvdW5kKS4geXQtZGxwIGl0c2VsZiBvbmx5IGVuYWJsZXMgRGVu
  >> "!B64TMP!" echo by4iIiIKICAgIGlmIHNodXRpbC53aGljaCgiZGVubyIpOgogICAgICAgIHJldHVybiBbXSwgVHJ1
  >> "!B64TMP!" echo ZQogICAgZm9yIGV4ZSwgbmFtZSBpbiAoKCJub2RlIiwgIm5vZGUiKSwgKCJidW4iLCAiYnVuIiks
  >> "!B64TMP!" echo ICgicWpzIiwgInF1aWNranMiKSwKICAgICAgICAgICAgICAgICAgICAgICgicXVpY2tqcyIsICJx
  >> "!B64TMP!" echo dWlja2pzIikpOgogICAgICAgIGlmIHNodXRpbC53aGljaChleGUpOgogICAgICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gWyItLWpzLXJ1bnRpbWVzIiwgbmFtZV0sIFRydWUKICAgIHJldHVybiBbXSwgRmFsc2UKCgpk
  >> "!B64TMP!" echo ZWYgcGFyc2VfanNvbjMocGF0aCk6CiAgICAiIiJZb3VUdWJlJ3MganNvbjMgY2FwdGlvbiBmaWxl
  >> "!B64TMP!" echo IC0+IFsoc3RhcnRfc2Vjb25kcywgdGV4dCksIC4uLl0uIiIiCiAgICB3aXRoIG9wZW4ocGF0aCwg
  >> "!B64TMP!" echo ZW5jb2Rpbmc9InV0Zi04IikgYXMgZmg6CiAgICAgICAgZGF0YSA9IGpzb24ubG9hZChmaCkKICAg
  >> "!B64TMP!" echo IG91dCA9IFtdCiAgICBmb3IgZXYgaW4gZGF0YS5nZXQoImV2ZW50cyIsIFtdKToKICAgICAgICBz
  >> "!B64TMP!" echo ZWdzID0gZXYuZ2V0KCJzZWdzIikKICAgICAgICBpZiBub3Qgc2VnczoKICAgICAgICAgICAgY29u
  >> "!B64TMP!" echo dGludWUKICAgICAgICB0ZXh0ID0gIiIuam9pbihzLmdldCgidXRmOCIsICIiKSBmb3IgcyBpbiBz
  >> "!B64TMP!" echo ZWdzKS5yZXBsYWNlKCJcbiIsICIgIikuc3RyaXAoKQogICAgICAgIGlmIHRleHQ6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIG91dC5hcHBlbmQoKChldi5nZXQoInRTdGFydE1zIikgb3IgMCkgLyAxMDAwLjAsIHRleHQp
  >> "!B64TMP!" echo KQogICAgcmV0dXJuIG91dAoKCmRlZiBwaWNrX2ZpbGUoZmlsZXMsIGxhbmdzKToKICAgICIiIkJl
  >> "!B64TMP!" echo c3QgY2FwdGlvbiBmaWxlIGZvciB0aGUgcmVxdWVzdGVkIGxhbmd1YWdlcyAoZXhhY3QgY29kZSwg
  >> "!B64TMP!" echo dGhlbiAtb3JpZywgdGhlbiBhbnkpLiIiIgogICAgZGVmIHJhbmsocGF0aCk6CiAgICAgICAgY29k
  >> "!B64TMP!" echo ZSA9IG9zLnBhdGguYmFzZW5hbWUocGF0aCkuc3BsaXQoIi4iKVstMl0gICMgPGlkPi48bGFuZz4u
  >> "!B64TMP!" echo anNvbjMKICAgICAgICBmb3IgaSwgbGFuZyBpbiBlbnVtZXJhdGUobGFuZ3MpOgogICAgICAgICAg
  >> "!B64TMP!" echo ICBpZiBjb2RlID09IGxhbmc6CiAgICAgICAgICAgICAgICByZXR1cm4gKGksIDApCiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGlmIGNvZGUgPT0gbGFuZyArICItb3JpZyI6CiAgICAgICAgICAgICAgICByZXR1cm4gKGks
  >> "!B64TMP!" echo IDEpCiAgICAgICAgICAgIGlmIGNvZGUuc3RhcnRzd2l0aChsYW5nKToKICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo IHJldHVybiAoaSwgMikKICAgICAgICByZXR1cm4gKGxlbihsYW5ncyksIDMpCiAgICByZXR1cm4g
  >> "!B64TMP!" echo c29ydGVkKGZpbGVzLCBrZXk9cmFuaylbMF0KCgpkZWYgYXZhaWxhYmxlX2xhbmd1YWdlcyhjbWQs
  >> "!B64TMP!" echo IHVybCk6CiAgICAiIiJMYW5ndWFnZSBjb2RlcyB5dC1kbHAgcmVwb3J0cyBmb3IgdGhlIHZpZGVv
  >> "!B64TMP!" echo IChmb3IgdGhlICdubyBzdWNoIGxhbmd1YWdlJyBtZXNzYWdlKS4iIiIKICAgIHRyeToKICAgICAg
  >> "!B64TMP!" echo ICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oY21kICsgWyItLXNraXAtZG93bmxvYWQiLCAiLS1saXN0
  >> "!B64TMP!" echo LXN1YnMiLCAiLS1uby13YXJuaW5ncyIsICItLSIsIHVybF0sCiAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgIGNhcHR1cmVfb3V0cHV0PVRydWUsIGVuY29kaW5nPSJ1dGYtOCIsIGVycm9ycz0i
  >> "!B64TMP!" echo cmVwbGFjZSIsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHRpbWVvdXQ9WVRETFBfVElN
  >> "!B64TMP!" echo RU9VVCkKICAgIGV4Y2VwdCAoT1NFcnJvciwgc3VicHJvY2Vzcy5TdWJwcm9jZXNzRXJyb3IpOgog
  >> "!B64TMP!" echo ICAgICAgIHJldHVybiBbXQogICAgY29kZXMgPSBbXQogICAgZm9yIGxpbmUgaW4gcHJvYy5zdGRv
  >> "!B64TMP!" echo dXQuc3BsaXRsaW5lcygpOgogICAgICAgIHBhcnRzID0gbGluZS5zcGxpdCgpCiAgICAgICAgaWYg
  >> "!B64TMP!" echo KHBhcnRzIGFuZCBub3QgbGluZS5zdGFydHN3aXRoKCgiWyIsICIgIikpIGFuZCBwYXJ0c1swXSAh
  >> "!B64TMP!" echo PSAiTGFuZ3VhZ2UiCiAgICAgICAgICAgICAgICBhbmQgcmUubWF0Y2gociJeW0EtWmEtel17Miwz
  >> "!B64TMP!" echo fSgtW0EtWmEtejAtOV0rKSokIiwgcGFydHNbMF0pCiAgICAgICAgICAgICAgICBhbmQgcGFydHNb
  >> "!B64TMP!" echo MF0gbm90IGluIGNvZGVzKToKICAgICAgICAgICAgY29kZXMuYXBwZW5kKHBhcnRzWzBdKQogICAg
  >> "!B64TMP!" echo cmV0dXJuIGNvZGVzWzoxNV0KCgpkZWYgZXhwbGFpbl95dGRscF9mYWlsdXJlKG91dHB1dCwgaGF2
  >> "!B64TMP!" echo ZV9ydW50aW1lKToKICAgIGxvdyA9IG91dHB1dC5sb3dlcigpCiAgICBpZiAic2lnbiBpbiB0byBj
  >> "!B64TMP!" echo b25maXJtIiBpbiBsb3cgb3IgIm5vdCBhIGJvdCIgaW4gbG93OgogICAgICAgIHdoeSA9ICgiWW91
  >> "!B64TMP!" echo VHViZSBhc2tlZCBmb3IgYSBzaWduLWluIC8gYm90IGNoZWNrIGZvciB0aGlzIHJlcXVlc3QuIFRo
  >> "!B64TMP!" echo aXMgaXMgY29tbW9uIGJlaGluZCBhICIKICAgICAgICAgICAgICAgIlZQTiwgcHJveHkgb3Igb24g
  >> "!B64TMP!" echo YSBkYXRhY2VudGVyIGNvbm5lY3Rpb24gLSB0cnkgYWdhaW4gbGF0ZXIgb3IgZnJvbSBhbm90aGVy
  >> "!B64TMP!" echo IG5ldHdvcmsuIikKICAgIGVsaWYgKCJqYXZhc2NyaXB0IHJ1bnRpbWUiIGluIGxvdyBvciAianMg
  >> "!B64TMP!" echo cnVudGltZSIgaW4gbG93IG9yICJuIGNoYWxsZW5nZSIgaW4gbG93CiAgICAgICAgICBvciAiY2hh
  >> "!B64TMP!" echo bGxlbmdlIHNvbHZpbmcgZmFpbGVkIiBpbiBsb3cgb3IgImVqcyIgaW4gbG93KToKICAgICAgICB3
  >> "!B64TMP!" echo aHkgPSAoInl0LWRscCBjb3VsZCBub3Qgc29sdmUgWW91VHViZSdzIEphdmFTY3JpcHQgY2hhbGxl
  >> "!B64TMP!" echo bmdlLiBJbnN0YWxsIERlbm8gb3IgTm9kZS5qcyAyMisgIgogICAgICAgICAgICAgICAiYW5kIHRo
  >> "!B64TMP!" echo ZSB5dC1kbHAtZWpzIHBhY2thZ2U6IHBpcCBpbnN0YWxsIC1VIFwieXQtZGxwW2RlZmF1bHRdXCIi
  >> "!B64TMP!" echo KQogICAgZWxpZiAicG8gdG9rZW4iIGluIGxvdyBvciAicG9fdG9rZW4iIGluIGxvdzoKICAgICAg
  >> "!B64TMP!" echo ICB3aHkgPSAiWW91VHViZSB3YW50cyBhIFBPIHRva2VuIGZvciB0aGlzIHZpZGVvIGFuZCB5dC1k
  >> "!B64TMP!" echo bHAgY291bGQgbm90IG9idGFpbiBvbmU7IHVwZGF0ZSB5dC1kbHA6IHBpcCBpbnN0YWxsIC1VIFwi
  >> "!B64TMP!" echo eXQtZGxwW2RlZmF1bHRdXCIiCiAgICBlbGlmICgicHJpdmF0ZSB2aWRlbyIgaW4gbG93IG9yICJt
  >> "!B64TMP!" echo ZW1iZXJzLW9ubHkiIGluIGxvdyBvciAibWVtYmVycyBvbmx5IiBpbiBsb3cKICAgICAgICAgIG9y
  >> "!B64TMP!" echo ICgic2lnbiBpbiIgaW4gbG93IGFuZCAiYWdlIiBpbiBsb3cpKToKICAgICAgICB3aHkgPSAiVGhl
  >> "!B64TMP!" echo IHZpZGVvIGlzIHByaXZhdGUsIG1lbWJlcnMtb25seSBvciBhZ2UtcmVzdHJpY3RlZCAtIG5vIHB1
  >> "!B64TMP!" echo YmxpYyB0cmFuc2NyaXB0IGlzIGF2YWlsYWJsZS4iCiAgICBlbGlmICJ2aWRlbyB1bmF2YWlsYWJs
  >> "!B64TMP!" echo ZSIgaW4gbG93IG9yICJ0aGlzIHZpZGVvIGlzIG5vdCBhdmFpbGFibGUiIGluIGxvdyBvciAiaGFz
  >> "!B64TMP!" echo IGJlZW4gcmVtb3ZlZCIgaW4gbG93OgogICAgICAgIHdoeSA9ICJUaGUgdmlkZW8gaXMgdW5hdmFp
  >> "!B64TMP!" echo bGFibGUgKHJlbW92ZWQsIHByaXZhdGUgb3IgcmVnaW9uLWxvY2tlZCkuIgogICAgZWxpZiAiaHR0
  >> "!B64TMP!" echo cCBlcnJvciA0MjkiIGluIGxvdyBvciAidG9vIG1hbnkgcmVxdWVzdHMiIGluIGxvdzoKICAgICAg
  >> "!B64TMP!" echo ICB3aHkgPSAiWW91VHViZSBpcyByYXRlLWxpbWl0aW5nIHRoaXMgY29ubmVjdGlvbiAoSFRUUCA0
  >> "!B64TMP!" echo MjkpLiBXYWl0IGEgd2hpbGUgYW5kIHJldHJ5LiIKICAgIGVsc2U6CiAgICAgICAgZXJycyA9IFts
  >> "!B64TMP!" echo bi5zdHJpcCgpIGZvciBsbiBpbiBvdXRwdXQuc3BsaXRsaW5lcygpIGlmICJlcnJvciIgaW4gbG4u
  >> "!B64TMP!" echo bG93ZXIoKV0KICAgICAgICB3aHkgPSBlcnJzWy0xXSBpZiBlcnJzIGVsc2UgInl0LWRscCBmaW5p
  >> "!B64TMP!" echo c2hlZCB3aXRob3V0IHdyaXRpbmcgYSB0cmFuc2NyaXB0LiIKICAgIGlmIG5vdCBoYXZlX3J1bnRp
  >> "!B64TMP!" echo bWUgYW5kICJqYXZhc2NyaXB0IiBub3QgaW4gd2h5Lmxvd2VyKCk6CiAgICAgICAgd2h5ICs9ICgi
  >> "!B64TMP!" echo IChObyBKYXZhU2NyaXB0IHJ1bnRpbWUgLSBEZW5vIG9yIE5vZGUuanMgMjIrIC0gd2FzIGZvdW5k
  >> "!B64TMP!" echo IG9uIFBBVEg7IFlvdVR1YmUgbmVlZHMgb25lIGZvciAiCiAgICAgICAgICAgICAgICAieXQtZGxw
  >> "!B64TMP!" echo IHRvIHdvcmsgcmVsaWFibHkuKSIpCiAgICByZXR1cm4gd2h5CgoKZGVmIGZldGNoX3dpdGhfeXRk
  >> "!B64TMP!" echo bHAoY21kLCB2aWRlb19pZCwgbGFuZ3MpOgogICAgdXJsID0gImh0dHBzOi8vd3d3LnlvdXR1YmUu
  >> "!B64TMP!" echo Y29tL3dhdGNoP3Y9IiArIHZpZGVvX2lkCiAgICBqc19hcmdzLCBoYXZlX3J1bnRpbWUgPSBqc19y
  >> "!B64TMP!" echo dW50aW1lX2FyZ3MoKQogICAgdG1wID0gdGVtcGZpbGUubWtkdGVtcChwcmVmaXg9ImxvY2FsLXNl
  >> "!B64TMP!" echo YXJjaC15dC0iKQogICAgdHJ5OgogICAgICAgIGJhc2UgPSBjbWQgKyBbIi0tc2tpcC1kb3dubG9h
  >> "!B64TMP!" echo ZCIsICItLW5vLXBsYXlsaXN0IiwgIi0tbm8tcHJvZ3Jlc3MiLCAiLS1uby13YXJuaW5ncyIsCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAiLS13cml0ZS1zdWJzIiwgIi0td3JpdGUtYXV0by1zdWJzIiwK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICItLXN1Yi1sYW5ncyIsICIsIi5qb2luKGwgKyAiLioiIGZv
  >> "!B64TMP!" echo ciBsIGluIGxhbmdzKSwKICAgICAgICAgICAgICAgICAgICAgICItLXN1Yi1mb3JtYXQiLCAianNv
  >> "!B64TMP!" echo bjMiLAogICAgICAgICAgICAgICAgICAgICAgIi1vIiwgb3MucGF0aC5qb2luKHRtcCwgIiUoaWQp
  >> "!B64TMP!" echo cy4lKGV4dClzIildCiAgICAgICAgcHJvYyA9IE5vbmUKICAgICAgICBmb3IgZXh0cmEgaW4gKFtq
  >> "!B64TMP!" echo c19hcmdzLCBbXV0gaWYganNfYXJncyBlbHNlIFtbXV0pOgogICAgICAgICAgICB0cnk6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oYmFzZSArIGV4dHJhICsgWyItLSIsIHVy
  >> "!B64TMP!" echo bF0sIGNhcHR1cmVfb3V0cHV0PVRydWUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJyZXBsYWNlIiwgdGltZW91dD1ZVERMUF9U
  >> "!B64TMP!" echo SU1FT1VUKQogICAgICAgICAgICBleGNlcHQgc3VicHJvY2Vzcy5UaW1lb3V0RXhwaXJlZDoKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIHJhaXNlIFRyYW5zY3JpcHRFcnJvcigieXQtZGxwIHRpbWVkIG91dCBhZnRl
  >> "!B64TMP!" echo ciAlZCBzLiIgJSBZVERMUF9USU1FT1VUKQogICAgICAgICAgICBleGNlcHQgT1NFcnJvciBhcyBl
  >> "!B64TMP!" echo eGM6CiAgICAgICAgICAgICAgICByYWlzZSBUcmFuc2NyaXB0RXJyb3IoImNvdWxkIG5vdCBydW4g
  >> "!B64TMP!" echo eXQtZGxwOiAlcyIgJSBleGMpCiAgICAgICAgICAgIGlmICJubyBzdWNoIG9wdGlvbjogLS1qcy1y
  >> "!B64TMP!" echo dW50aW1lcyIgbm90IGluIHByb2Muc3RkZXJyOgogICAgICAgICAgICAgICAgYnJlYWsgICMgYW4g
  >> "!B64TMP!" echo b2xkIHl0LWRscCB3aXRob3V0IC0tanMtcnVudGltZXMgaXMgcmV0cmllZCB3aXRob3V0IGl0CiAg
  >> "!B64TMP!" echo ICAgICAgZmlsZXMgPSBnbG9iLmdsb2Iob3MucGF0aC5qb2luKHRtcCwgZ2xvYi5lc2NhcGUodmlk
  >> "!B64TMP!" echo ZW9faWQpICsgIi4qLmpzb24zIikpCiAgICAgICAgaWYgbm90IGZpbGVzOgogICAgICAgICAgICBv
  >> "!B64TMP!" echo dXRwdXQgPSAocHJvYy5zdGRvdXQgb3IgIiIpICsgIlxuIiArIChwcm9jLnN0ZGVyciBvciAiIikK
  >> "!B64TMP!" echo ICAgICAgICAgICAgaWYgcHJvYy5yZXR1cm5jb2RlID09IDAgYW5kICJubyBzdWJ0aXRsZXMiIGlu
  >> "!B64TMP!" echo IG91dHB1dC5sb3dlcigpOgogICAgICAgICAgICAgICAgbGFuZ3NfZm91bmQgPSBhdmFpbGFibGVf
  >> "!B64TMP!" echo bGFuZ3VhZ2VzKGNtZCwgdXJsKQogICAgICAgICAgICAgICAgbXNnID0gInRoZSB2aWRlbyBoYXMg
  >> "!B64TMP!" echo bm8gY2FwdGlvbnMgaW46ICVzLiIgJSAiLCAiLmpvaW4obGFuZ3MpCiAgICAgICAgICAgICAgICBp
  >> "!B64TMP!" echo ZiBsYW5nc19mb3VuZDoKICAgICAgICAgICAgICAgICAgICBtc2cgKz0gIiBBdmFpbGFibGU6ICVz
  >> "!B64TMP!" echo IC0gY2hvb3NlIG9uZSB3aXRoIC0tbGFuZy4iICUgIiwgIi5qb2luKGxhbmdzX2ZvdW5kKQogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmFpc2UgVHJhbnNjcmlwdEVycm9yKG1zZykKICAgICAgICAgICAgcmFpc2Ug
  >> "!B64TMP!" echo VHJhbnNjcmlwdEVycm9yKGV4cGxhaW5feXRkbHBfZmFpbHVyZShvdXRwdXQsIGhhdmVfcnVudGlt
  >> "!B64TMP!" echo ZSkpCiAgICAgICAgbGluZXMgPSBwYXJzZV9qc29uMyhwaWNrX2ZpbGUoZmlsZXMsIGxhbmdzKSkK
  >> "!B64TMP!" echo ICAgICAgICBpZiBub3QgbGluZXM6CiAgICAgICAgICAgIHJhaXNlIFRyYW5zY3JpcHRFcnJvcigi
  >> "!B64TMP!" echo dGhlIGNhcHRpb24gZmlsZSB3YXMgZW1wdHkuIikKICAgICAgICByZXR1cm4gbGluZXMKICAgIGZp
  >> "!B64TMP!" echo bmFsbHk6CiAgICAgICAgc2h1dGlsLnJtdHJlZSh0bXAsIGlnbm9yZV9lcnJvcnM9VHJ1ZSkKCgoj
  >> "!B64TMP!" echo IC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0geW91dHVi
  >> "!B64TMP!" echo ZS10cmFuc2NyaXB0LWFwaSAoZmFsbGJhY2spCmRlZiBmZXRjaF93aXRoX2FwaSh2aWRlb19pZCwg
  >> "!B64TMP!" echo bGFuZ3MpOgogICAgZnJvbSB5b3V0dWJlX3RyYW5zY3JpcHRfYXBpIGltcG9ydCBZb3VUdWJlVHJh
  >> "!B64TMP!" echo bnNjcmlwdEFwaSAgIyBJbXBvcnRFcnJvciBoYW5kbGVkIGJ5IGNhbGxlcgogICAgdHJhbnNjcmlw
  >> "!B64TMP!" echo dCA9IFlvdVR1YmVUcmFuc2NyaXB0QXBpKCkuZmV0Y2godmlkZW9faWQsIGxhbmd1YWdlcz1sYW5n
  >> "!B64TMP!" echo cykKICAgIHJldHVybiBbKHNlZy5zdGFydCwgc2VnLnRleHQucmVwbGFjZSgiXG4iLCAiICIpKSBm
  >> "!B64TMP!" echo b3Igc2VnIGluIHRyYW5zY3JpcHQuc25pcHBldHNdCgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gbWFpbgpk
  >> "!B64TMP!" echo ZWYgcGFyc2VfYXJncyhhcmd2KToKICAgIHZpZGVvLCBsYW5ncywgaSA9IE5vbmUsIFsiZW4iXSwg
  >> "!B64TMP!" echo MAogICAgd2hpbGUgaSA8IGxlbihhcmd2KToKICAgICAgICBhID0gYXJndltpXQogICAgICAgIGlm
  >> "!B64TMP!" echo IGEgaW4gKCItLWxhbmciLCAiLS1sYW5ncyIsICItbCIpIGFuZCBpICsgMSA8IGxlbihhcmd2KToK
  >> "!B64TMP!" echo ICAgICAgICAgICAgbGFuZ3MgPSBbeC5zdHJpcCgpIGZvciB4IGluIGFyZ3ZbaSArIDFdLnNwbGl0
  >> "!B64TMP!" echo KCIsIikgaWYgeC5zdHJpcCgpXQogICAgICAgICAgICBpICs9IDIKICAgICAgICBlbGlmIGEuc3Rh
  >> "!B64TMP!" echo cnRzd2l0aCgiLS1sYW5nPSIpOgogICAgICAgICAgICBsYW5ncyA9IFt4LnN0cmlwKCkgZm9yIHgg
  >> "!B64TMP!" echo aW4gYS5zcGxpdCgiPSIsIDEpWzFdLnNwbGl0KCIsIikgaWYgeC5zdHJpcCgpXQogICAgICAgICAg
  >> "!B64TMP!" echo ICBpICs9IDEKICAgICAgICBlbGlmIHZpZGVvIGlzIE5vbmUgYW5kIG5vdCBhLnN0YXJ0c3dpdGgo
  >> "!B64TMP!" echo Ii0iKToKICAgICAgICAgICAgdmlkZW8gPSBhCiAgICAgICAgICAgIGkgKz0gMQogICAgICAgIGVs
  >> "!B64TMP!" echo c2U6CiAgICAgICAgICAgIHJldHVybiBOb25lLCBOb25lCiAgICBpZiB2aWRlbyBpcyBOb25lIG9y
  >> "!B64TMP!" echo IG5vdCBsYW5ncyBvciBub3QgYWxsKExBTkcubWF0Y2gobCkgZm9yIGwgaW4gbGFuZ3MpOgogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiBOb25lLCBOb25lCiAgICByZXR1cm4gdmlkZW8sIGxhbmdzCgoKZGVmIG1haW4o
  >> "!B64TMP!" echo YXJndj1Ob25lKToKICAgIHZpZGVvLCBsYW5ncyA9IHBhcnNlX2FyZ3Moc3lzLmFyZ3ZbMTpdIGlm
  >> "!B64TMP!" echo IGFyZ3YgaXMgTm9uZSBlbHNlIGFyZ3YpCiAgICBpZiB2aWRlbyBpcyBOb25lOgogICAgICAgIHBy
  >> "!B64TMP!" echo aW50KCJ1c2FnZTogd2ViX3lvdXR1YmVfdHJhbnNjcmlwdC5weSA8dmlkZW9faWQgfCB5b3V0dWJl
  >> "!B64TMP!" echo IHVybD4gWy0tbGFuZyBlbixkZV0iLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gMgogICAgdmlkZW9faWQgPSB2aWRlb19pZF9mcm9tKHZpZGVvKQogICAgaWYg
  >> "!B64TMP!" echo bm90IHZpZGVvX2lkOgogICAgICAgIHByaW50KCJUUkFOU0NSSVBUIEZBSUxFRDogJyVzJyBpcyBu
  >> "!B64TMP!" echo b3QgYSBZb3VUdWJlIHZpZGVvIGlkIG9yIFVSTC4iICUgdmlkZW8sIGZpbGU9c3lzLnN0ZGVycikK
  >> "!B64TMP!" echo ICAgICAgICByZXR1cm4gMgoKICAgIHByb2JsZW1zID0gW10KICAgIGxpbmVzID0gTm9uZQogICAg
  >> "!B64TMP!" echo Y21kID0geXRkbHBfY29tbWFuZCgpCiAgICBpZiBjbWQ6CiAgICAgICAgdHJ5OgogICAgICAgICAg
  >> "!B64TMP!" echo ICBsaW5lcyA9IGZldGNoX3dpdGhfeXRkbHAoY21kLCB2aWRlb19pZCwgbGFuZ3MpCiAgICAgICAg
  >> "!B64TMP!" echo ZXhjZXB0IFRyYW5zY3JpcHRFcnJvciBhcyBleGM6CiAgICAgICAgICAgIHByb2JsZW1zLmFwcGVu
  >> "!B64TMP!" echo ZCgieXQtZGxwOiAlcyIgJSBleGMpCiAgICBlbHNlOgogICAgICAgIHByb2JsZW1zLmFwcGVuZCgi
  >> "!B64TMP!" echo eXQtZGxwIGlzIG5vdCBpbnN0YWxsZWQuIikKCiAgICBpZiBsaW5lcyBpcyBOb25lOgogICAgICAg
  >> "!B64TMP!" echo IHRyeToKICAgICAgICAgICAgbGluZXMgPSBmZXRjaF93aXRoX2FwaSh2aWRlb19pZCwgbGFuZ3Mp
  >> "!B64TMP!" echo CiAgICAgICAgICAgIGlmIGNtZDoKICAgICAgICAgICAgICAgIHByaW50KCIoeXQtZGxwIGZhaWxl
  >> "!B64TMP!" echo ZCAtIHVzZWQgdGhlIHlvdXR1YmUtdHJhbnNjcmlwdC1hcGkgZmFsbGJhY2spIiwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIGV4Y2VwdCBJbXBvcnRFcnJvcjoKICAgICAgICAgICAgcGFzcwogICAg
  >> "!B64TMP!" echo ICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOiAgIyBub3FhOiBCTEUwMDEgLSBsaWJyYXJ5IGVy
  >> "!B64TMP!" echo cm9ycyBhcmUgdXNlci1mYWNpbmcgdGV4dAogICAgICAgICAgICBuYW1lID0gdHlwZShleGMpLl9f
  >> "!B64TMP!" echo bmFtZV9fCiAgICAgICAgICAgIGhpbnQgPSAoIiAoWW91VHViZSByZXF1aXJlcyBhIFBPIHRva2Vu
  >> "!B64TMP!" echo IGZvciB0aGlzIHZpZGVvIC0gb25seSB5dC1kbHAgY2FuIHJlYWQgaXQpIgogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIGlmICJQb1Rva2VuIiBpbiBuYW1lIG9yICJ4cGUiIGluIHN0cihleGMpIGVsc2UgIiIp
  >> "!B64TMP!" echo CiAgICAgICAgICAgIHByb2JsZW1zLmFwcGVuZCgieW91dHViZS10cmFuc2NyaXB0LWFwaTogJXMl
  >> "!B64TMP!" echo cyIgJSAobmFtZSwgaGludCkpCgogICAgaWYgbGluZXMgaXMgTm9uZToKICAgICAgICBwcmludCgi
  >> "!B64TMP!" echo VFJBTlNDUklQVCBGQUlMRUQgZm9yICVzOiIgJSB2aWRlb19pZCwgZmlsZT1zeXMuc3RkZXJyKQog
  >> "!B64TMP!" echo ICAgICAgIGZvciBwIGluIHByb2JsZW1zOgogICAgICAgICAgICBwcmludCgiICAtICIgKyBwLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgbm90IGNtZDoKICAgICAgICAgICAgcHJpbnQoIklu
  >> "!B64TMP!" echo c3RhbGwgdGhlIHJlbGlhYmxlIGVuZ2luZTogIHBpcCBpbnN0YWxsIC1VIFwieXQtZGxwW2RlZmF1
  >> "!B64TMP!" echo bHRdXCJcbiIKICAgICAgICAgICAgICAgICAgImFuZCBoYXZlIERlbm8gb3IgTm9kZS5qcyAyMisg
  >> "!B64TMP!" echo b24gUEFUSCAoWW91VHViZSBuZWVkcyBhIEphdmFTY3JpcHQgcnVudGltZSkuIiwKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgZm9yIHN0YXJ0
  >> "!B64TMP!" echo LCB0ZXh0IGluIGxpbmVzOgogICAgICAgIG1pbnMsIHNlY3MgPSBpbnQoc3RhcnQpIC8vIDYwLCBp
  >> "!B64TMP!" echo bnQoc3RhcnQpICUgNjAKICAgICAgICBwcmludCgiWyUwMmQ6JTAyZF0gJXMiICUgKG1pbnMsIHNl
  >> "!B64TMP!" echo Y3MsIHRleHQpKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAg
  >> "!B64TMP!" echo c3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_youtube_transcript.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_map.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_map.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_map.py" "!TARGET!\local-web-search\scripts\web_map.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_map.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_map.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3466815660.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJNYXAgYSB3ZWJzaXRlOiBlbnVtZXJhdGUgdGhlIFVS
  >> "!B64TMP!" echo THMgRmlyZWNyYXdsIGluZGV4ZXMgdW5kZXIgaXQsIHdpdGhvdXQKZmV0Y2hpbmcgZWFjaCBwYWdl
  >> "!B64TMP!" echo J3MgY29udGVudCAodGhlIGZpcmVjcmF3bF9tYXAgTUNQIHRvb2wpLgoKVXNhZ2U6CiAgICBweXRo
  >> "!B64TMP!" echo b24gd2ViX21hcC5weSA8dXJsPiBbLS1zZWFyY2ggdGVybV0gWy0tbGltaXQgTl0gWy0tanNvbl0K
  >> "!B64TMP!" echo ClNlbGYtaGVhbGluZzogaWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAo
  >> "!B64TMP!" echo RG9ja2VyIGVuZ2luZSBvciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1
  >> "!B64TMP!" echo dG9tYXRpY2FsbHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5w
  >> "!B64TMP!" echo eSAvIFJ1bi5iYXQpIGFuZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVz
  >> "!B64TMP!" echo CnNlbGYtaGVhbCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdp
  >> "!B64TMP!" echo dGggYSBzaG9ydCBiYWNrb2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5w
  >> "!B64TMP!" echo eSBmaXJzdCDigJQganVzdCBydW4gdGhlIHNjcmlwdC4KCmAtLXNlYXJjaGAgZmlsdGVycy9ib29z
  >> "!B64TMP!" echo dHMgVVJMcyBjb250YWluaW5nIHRoZSB0ZXJtIChzZXJ2ZXItc2lkZSkuIFByaW50cyB1cAp0byBg
  >> "!B64TMP!" echo bGltaXRgIFVSTHMgKGRlZmF1bHQgMTAwKSwgb25lIHBlciBsaW5lLCBudW1iZXJlZC4gYC0tanNv
  >> "!B64TMP!" echo bmAgcHJpbnRzIHRoZQpyYXcgQVBJIHJlc3BvbnNlIGluc3RlYWQuCiIiIgppbXBvcnQganNvbgpp
  >> "!B64TMP!" echo bXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShv
  >> "!B64TMP!" echo cy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMg
  >> "!B64TMP!" echo c2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZj
  >> "!B64TMP!" echo LnVybCgiL3YxL21hcCIpCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3Zb
  >> "!B64TMP!" echo MTpdCiAgICBpZiBub3QgYXJncyBvciBhcmdzWzBdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAg
  >> "!B64TMP!" echo cHJpbnQoInVzYWdlOiB3ZWJfbWFwLnB5IDx1cmw+IFstLXNlYXJjaCB0ZXJtXSBbLS1saW1pdCBO
  >> "!B64TMP!" echo XSBbLS1qc29uXSIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVy
  >> "!B64TMP!" echo biAyCiAgICB1cmwgPSBhcmdzWzBdCiAgICBzZWFyY2gsIGxpbWl0LCBhc19qc29uID0gTm9uZSwg
  >> "!B64TMP!" echo MTAwLCBGYWxzZQogICAgaSA9IDEKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9
  >> "!B64TMP!" echo IGFyZ3NbaV0KICAgICAgICBpZiBhID09ICItLXNlYXJjaCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3Mp
  >> "!B64TMP!" echo OgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgc2VhcmNoID0gYXJnc1tpXQogICAgICAg
  >> "!B64TMP!" echo IGVsaWYgYSA9PSAiLS1saW1pdCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBp
  >> "!B64TMP!" echo ICs9IDEKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgbGltaXQgPSBpbnQoYXJnc1tp
  >> "!B64TMP!" echo XSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBwcmludChm
  >> "!B64TMP!" echo ImludmFsaWQgLS1saW1pdDoge2FyZ3NbaV19IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tanNvbiI6CiAgICAgICAgICAgIGFz
  >> "!B64TMP!" echo X2pzb24gPSBUcnVlCiAgICAgICAgZWxpZiBhLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IHByaW50KGYidW5rbm93biBvcHRpb246IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIDIKICAgICAgICBlbHNlOgogICAgICAgICAgICBwcmludChmInVuZXhwZWN0ZWQg
  >> "!B64TMP!" echo YXJndW1lbnQ6IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDIKICAg
  >> "!B64TMP!" echo ICAgICBpICs9IDEKCiAgICBib2R5ID0geyJ1cmwiOiB1cmx9CiAgICBpZiBzZWFyY2g6CiAgICAg
  >> "!B64TMP!" echo ICAgYm9keVsic2VhcmNoIl0gPSBzZWFyY2gKCiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNh
  >> "!B64TMP!" echo bGwoIi92MS9tYXAiLCBtZXRob2Q9IlBPU1QiLCBib2R5PWJvZHkpCiAgICBleGNlcHQgZmMuRmNF
  >> "!B64TMP!" echo cnJvciBhcyBlOgogICAgICAgIHByaW50KGYiTUFQIEZBSUxFRCBmb3Ige3VybH06IHtlfSIsIGZp
  >> "!B64TMP!" echo bGU9c3lzLnN0ZGVycikKICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGlu
  >> "!B64TMP!" echo dCwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAg
  >> "!B64TMP!" echo ICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCgogICAgbGlua3Mg
  >> "!B64TMP!" echo PSBkYXRhLmdldCgibGlua3MiKQogICAgaWYgbGlua3MgaXMgTm9uZToKICAgICAgICBwYXlsb2Fk
  >> "!B64TMP!" echo ID0gZGF0YS5nZXQoImRhdGEiKQogICAgICAgIGlmIGlzaW5zdGFuY2UocGF5bG9hZCwgZGljdCk6
  >> "!B64TMP!" echo CiAgICAgICAgICAgIGxpbmtzID0gcGF5bG9hZC5nZXQoImxpbmtzIikKICAgIGlmIG5vdCBpc2lu
  >> "!B64TMP!" echo c3RhbmNlKGxpbmtzLCBsaXN0KToKICAgICAgICBsaW5rcyA9IFtdCiAgICBpZiBub3QgbGlua3M6
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoIihubyBVUkxzIGZvdW5kKSIpCiAgICAgICAgcmV0dXJuIDAKICAgIGZv
  >> "!B64TMP!" echo ciBuLCBsaW5rIGluIGVudW1lcmF0ZShsaW5rc1s6bGltaXRdLCAxKToKICAgICAgICBwcmludChm
  >> "!B64TMP!" echo IntufS4ge2xpbmt9IikKICAgIGlmIGxlbihsaW5rcykgPiBsaW1pdDoKICAgICAgICBwcmludChm
  >> "!B64TMP!" echo IlsuLi4ge2xlbihsaW5rcykgLSBsaW1pdH0gbW9yZSBVUkxzOyByYWlzZSAtLWxpbWl0IG9yIHVz
  >> "!B64TMP!" echo ZSAtLWpzb24gLi4uXSIsCiAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgcmV0dXJu
  >> "!B64TMP!" echo IDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_map.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_crawl.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_crawl.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_crawl.py" "!TARGET!\local-web-search\scripts\web_crawl.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_crawl.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_crawl.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3421326922.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSdW4gYSBzaXRlIGNyYXdsOiBzdGFydCBhIG11bHRp
  >> "!B64TMP!" echo LXBhZ2UgRmlyZWNyYXdsIGNyYXdsIGF0IGEgVVJMLCBwb2xsIGl0IHRvCmEgdGVybWluYWwgc3Rh
  >> "!B64TMP!" echo dGUsIGFuZCByZXBvcnQgdGhlIGZpbmFsIHN0YXR1cyBhbmQgY29sbGVjdGVkIGRhdGEgKHRoZQpm
  >> "!B64TMP!" echo aXJlY3Jhd2xfY3Jhd2wgTUNQIHRvb2wpLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2NyYXdsLnB5
  >> "!B64TMP!" echo IDx1cmw+IFstLWxpbWl0IE5dIFstLXRpbWVvdXQgU10gWy0tcG9sbC1pbnRlcnZhbCBTXQogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICBbLS1tYXgtcGFnZXMgTl0gWy0tbWF4LWNoYXJzIE5dIFstLWpz
  >> "!B64TMP!" echo b25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFi
  >> "!B64TMP!" echo bGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlw
  >> "!B64TMP!" echo dCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3Rh
  >> "!B64TMP!" echo Y2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWls
  >> "!B64TMP!" echo dXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmll
  >> "!B64TMP!" echo ZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3Rh
  >> "!B64TMP!" echo Y2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpQb2xscyB0aGUgY3Jhd2wgZXZl
  >> "!B64TMP!" echo cnkgLS1wb2xsLWludGVydmFsIHNlY29uZHMgKGRlZmF1bHQgMikgdW50aWwgaXQgcmVhY2hlcyBh
  >> "!B64TMP!" echo CnRlcm1pbmFsIHN0YXRlIChjb21wbGV0ZWQgLyBmYWlsZWQgLyBjYW5jZWxsZWQpIG9yIC0tdGlt
  >> "!B64TMP!" echo ZW91dCBzZWNvbmRzIGVsYXBzZQooZGVmYXVsdCAzMDApLiBQcm9ncmVzcyBpcyBwcmludGVkIHRv
  >> "!B64TMP!" echo IHN0ZGVyci4gV2hlbiB0aGUgY3Jhd2wgY29tcGxldGVzLCBlYWNoCmNvbGxlY3RlZCBwYWdlIHBy
  >> "!B64TMP!" echo aW50cyBhcyBgTi4gPHVybD5gIGZvbGxvd2VkIGJ5IGl0cyBtYXJrZG93biB0cnVuY2F0ZWQgYXQK
  >> "!B64TMP!" echo LS1tYXgtY2hhcnMgY2hhcnMgKGRlZmF1bHQgMjAwMDsgdXAgdG8gLS1tYXgtcGFnZXMgcGFnZXMs
  >> "!B64TMP!" echo IGRlZmF1bHQgMjUpLgpgLS1qc29uYCBwcmludHMgdGhlIGZpbmFsIHN0YXR1cyByZXNwb25zZSBp
  >> "!B64TMP!" echo bnN0ZWFkLgoKSWYgdGhlIGNyYXdsIGhhcyBub3QgZmluaXNoZWQgd2l0aGluIC0tdGltZW91dCwg
  >> "!B64TMP!" echo dGhlIGNyYXdsIElEIGFuZCBjdXJyZW50CnByb2dyZXNzIGFyZSBwcmludGVkIOKAlCBrZWVwIHBv
  >> "!B64TMP!" echo bGxpbmcgd2l0aCB3ZWJfY3Jhd2xfc3RhdHVzLnB5IDxpZD4uCiIiIgppbXBvcnQganNvbgppbXBv
  >> "!B64TMP!" echo cnQgb3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGgu
  >> "!B64TMP!" echo ZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkg
  >> "!B64TMP!" echo YXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQ
  >> "!B64TMP!" echo T0lOVCA9IGZjLnVybCgiL3YxL2NyYXdsIikKCiMgQ3Jhd2wtam9iIHN0YXRlcyB0aGF0IG1lYW4g
  >> "!B64TMP!" echo Im5vIG1vcmUgcG9sbGluZyIuClRFUk1JTkFMID0gKCJjb21wbGV0ZWQiLCAiZmFpbGVkIiwgImNh
  >> "!B64TMP!" echo bmNlbGxlZCIsICJzdG9wcGVkIikKCgpkZWYgY3Jhd2xfc3VtbWFyeShkYXRhKToKICAgICIiIk9u
  >> "!B64TMP!" echo ZS1saW5lIHN0YXR1cyBzdW1tYXJ5IGZyb20gYSBjcmF3bC1zdGF0dXMgcGF5bG9hZC4iIiIKICAg
  >> "!B64TMP!" echo IHN0YXR1cyA9IGRhdGEuZ2V0KCJzdGF0dXMiKSBvciAidW5rbm93biIKICAgIGNvbXBsZXRlZCA9
  >> "!B64TMP!" echo IGRhdGEuZ2V0KCJjb21wbGV0ZWQiKQogICAgdG90YWwgPSBkYXRhLmdldCgidG90YWwiKQogICAg
  >> "!B64TMP!" echo aWYgY29tcGxldGVkIGlzIG5vdCBOb25lIGFuZCB0b3RhbCBpcyBub3QgTm9uZToKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gZiJ7c3RhdHVzfSAoe2NvbXBsZXRlZH0ve3RvdGFsfSBwYWdlcykiCiAgICByZXR1cm4g
  >> "!B64TMP!" echo c3RyKHN0YXR1cykKCgpkZWYgcHJpbnRfcGFnZXMoZGF0YSwgbWF4X3BhZ2VzLCBtYXhfY2hhcnMp
  >> "!B64TMP!" echo OgogICAgIiIiUHJpbnQgdGhlIGNvbGxlY3RlZCBwYWdlczogYE4uIDx1cmw+YCArIHRydW5jYXRl
  >> "!B64TMP!" echo ZCBtYXJrZG93bi4iIiIKICAgIHBhZ2VzID0gZGF0YS5nZXQoImRhdGEiKQogICAgaWYgbm90IGlz
  >> "!B64TMP!" echo aW5zdGFuY2UocGFnZXMsIGxpc3QpIG9yIG5vdCBwYWdlczoKICAgICAgICByZXR1cm4KICAgIHNo
  >> "!B64TMP!" echo b3duID0gcGFnZXNbOm1heF9wYWdlc10KICAgIGZvciBuLCBwYWdlIGluIGVudW1lcmF0ZShzaG93
  >> "!B64TMP!" echo biwgMSk6CiAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UocGFnZSwgZGljdCk6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IGNvbnRpbnVlCiAgICAgICAgbWV0YWRhdGEgPSBwYWdlLmdldCgibWV0YWRhdGEiKQogICAgICAg
  >> "!B64TMP!" echo IGlmIG5vdCBpc2luc3RhbmNlKG1ldGFkYXRhLCBkaWN0KToKICAgICAgICAgICAgbWV0YWRhdGEg
  >> "!B64TMP!" echo PSB7fQogICAgICAgIHVybCA9IHBhZ2UuZ2V0KCJ1cmwiKSBvciBwYWdlLmdldCgic291cmNlVVJM
  >> "!B64TMP!" echo IikgXAogICAgICAgICAgICBvciBtZXRhZGF0YS5nZXQoInVybCIpIG9yIG1ldGFkYXRhLmdldCgi
  >> "!B64TMP!" echo c291cmNlVVJMIikgb3IgIihubyB1cmwpIgogICAgICAgIHByaW50KGYie259LiB7dXJsfSIpCiAg
  >> "!B64TMP!" echo ICAgICAgbWFya2Rvd24gPSBwYWdlLmdldCgibWFya2Rvd24iKSBvciAiIgogICAgICAgIGlmIG1h
  >> "!B64TMP!" echo cmtkb3duOgogICAgICAgICAgICBpZiBsZW4obWFya2Rvd24pID4gbWF4X2NoYXJzOgogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgbWFya2Rvd24gPSBtYXJrZG93bls6bWF4X2NoYXJzXSBcCiAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgKyBmIlxuICAgWy4uLiB0cnVuY2F0ZWQgYXQge21heF9jaGFyc30gY2hhcnMgLi4uXSIK
  >> "!B64TMP!" echo ICAgICAgICAgICAgZm9yIGxpbmUgaW4gbWFya2Rvd24uc3BsaXRsaW5lcygpIG9yIFsiIl06CiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBwcmludChmIiAgIHtsaW5lfSIpCiAgICBpZiBsZW4ocGFnZXMpID4gbWF4
  >> "!B64TMP!" echo X3BhZ2VzOgogICAgICAgIHByaW50KGYiWy4uLiB7bGVuKHBhZ2VzKSAtIG1heF9wYWdlc30gbW9y
  >> "!B64TMP!" echo ZSBwYWdlczsgcmFpc2UgLS1tYXgtcGFnZXMgIgogICAgICAgICAgICAgIGYib3IgdXNlIC0tanNv
  >> "!B64TMP!" echo biAuLi5dIiwgZmlsZT1zeXMuc3RkZXJyKQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9
  >> "!B64TMP!" echo IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mgb3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIp
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX2NyYXdsLnB5IDx1cmw+IFstLWxpbWl0IE5dIFst
  >> "!B64TMP!" echo LXRpbWVvdXQgU10gIgogICAgICAgICAgICAgICJbLS1wb2xsLWludGVydmFsIFNdIFstLW1heC1w
  >> "!B64TMP!" echo YWdlcyBOXSBbLS1tYXgtY2hhcnMgTl0gWy0tanNvbl0iLAogICAgICAgICAgICAgIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICByZXR1cm4gMgogICAgdXJsID0gYXJnc1swXQogICAgbGltaXQgPSBO
  >> "!B64TMP!" echo b25lCiAgICB0aW1lb3V0LCBwb2xsX2V2ZXJ5ID0gMzAwLCAyCiAgICBtYXhfcGFnZXMsIG1heF9j
  >> "!B64TMP!" echo aGFycywgYXNfanNvbiA9IDI1LCAyMDAwLCBGYWxzZQogICAgaSA9IDEKCiAgICBkZWYgbnVtKG5h
  >> "!B64TMP!" echo bWUpOgogICAgICAgICMgYGlgIGFscmVhZHkgcG9pbnRzIGF0IHRoZSBvcHRpb24ncyB2YWx1ZSAo
  >> "!B64TMP!" echo dGhlIGJyYW5jaCBpbmNyZW1lbnRlZCBpdCkuCiAgICAgICAgdHJ5OgogICAgICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gaW50KGFyZ3NbaV0pCiAgICAgICAgZXhjZXB0IChWYWx1ZUVycm9yLCBJbmRleEVycm9yKToK
  >> "!B64TMP!" echo ICAgICAgICAgICAgcHJpbnQoZiJpbnZhbGlkIHtuYW1lfToge2FyZ3NbaV0gaWYgaSA8IGxlbihh
  >> "!B64TMP!" echo cmdzKSBlbHNlICcnfSIsCiAgICAgICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAg
  >> "!B64TMP!" echo ICAgICAgc3lzLmV4aXQoMikKCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAgICAgIGEgPSBh
  >> "!B64TMP!" echo cmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1saW1pdCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgog
  >> "!B64TMP!" echo ICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgbGltaXQgPSBudW0oIi0tbGltaXQiKQogICAg
  >> "!B64TMP!" echo ICAgIGVsaWYgYSA9PSAiLS10aW1lb3V0IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGkgKz0gMQogICAgICAgICAgICB0aW1lb3V0ID0gbnVtKCItLXRpbWVvdXQiKQogICAgICAg
  >> "!B64TMP!" echo IGVsaWYgYSA9PSAiLS1wb2xsLWludGVydmFsIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIGkgKz0gMQogICAgICAgICAgICBwb2xsX2V2ZXJ5ID0gbnVtKCItLXBvbGwtaW50ZXJ2
  >> "!B64TMP!" echo YWwiKQogICAgICAgIGVsaWYgYSA9PSAiLS1tYXgtcGFnZXMiIGFuZCBpICsgMSA8IGxlbihhcmdz
  >> "!B64TMP!" echo KToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIG1heF9wYWdlcyA9IG51bSgiLS1tYXgt
  >> "!B64TMP!" echo cGFnZXMiKQogICAgICAgIGVsaWYgYSA9PSAiLS1tYXgtY2hhcnMiIGFuZCBpICsgMSA8IGxlbihh
  >> "!B64TMP!" echo cmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIG1heF9jaGFycyA9IG51bSgiLS1t
  >> "!B64TMP!" echo YXgtY2hhcnMiKQogICAgICAgIGVsaWYgYSA9PSAiLS1qc29uIjoKICAgICAgICAgICAgYXNfanNv
  >> "!B64TMP!" echo biA9IFRydWUKICAgICAgICBlbGlmIGEuc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICAgICAgcHJp
  >> "!B64TMP!" echo bnQoZiJ1bmtub3duIG9wdGlvbjoge2F9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4gMgogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHByaW50KGYidW5leHBlY3RlZCBhcmd1
  >> "!B64TMP!" echo bWVudDoge2F9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMgogICAgICAg
  >> "!B64TMP!" echo IGkgKz0gMQoKICAgIGJvZHkgPSB7InVybCI6IHVybH0KICAgIGlmIGxpbWl0OgogICAgICAgIGJv
  >> "!B64TMP!" echo ZHlbImxpbWl0Il0gPSBsaW1pdAoKICAgICMgLS0tLSBzdGFydCB0aGUgY3Jhd2wgLS0tLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAgICB0cnk6CiAgICAgICAg
  >> "!B64TMP!" echo c3RhcnRlZCA9IGZjLmNhbGwoIi92MS9jcmF3bCIsIG1ldGhvZD0iUE9TVCIsIGJvZHk9Ym9keSkK
  >> "!B64TMP!" echo ICAgIGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJDUkFXTCBGQUlMRUQg
  >> "!B64TMP!" echo Zm9yIHt1cmx9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAg
  >> "!B64TMP!" echo ICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQog
  >> "!B64TMP!" echo ICAgY3Jhd2xfaWQgPSBzdGFydGVkLmdldCgiaWQiKSBvciAoc3RhcnRlZC5nZXQoImRhdGEiKSBv
  >> "!B64TMP!" echo ciB7fSkuZ2V0KCJpZCIpCiAgICBpZiBub3QgY3Jhd2xfaWQ6CiAgICAgICAgcHJpbnQoIkNSQVdM
  >> "!B64TMP!" echo IEZBSUxFRCBmb3Ige306IHRoZSBBUEkgZGlkIG5vdCByZXR1cm4gYSBjcmF3bCBpZC4gIgogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICJSZXNwb25zZToiLmZvcm1hdCh1cmwpLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAg
  >> "!B64TMP!" echo ICAgcHJpbnQoanNvbi5kdW1wcyhzdGFydGVkKVs6ODAwXSwgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiAxCiAgICBwcmludChmIkNyYXdsIHN0YXJ0ZWQ6IHtjcmF3bF9pZH0iLCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCgogICAgIyAtLS0tIHBvbGwgdG8gYSB0ZXJtaW5hbCBzdGF0ZSAtLS0tLS0t
  >> "!B64TMP!" echo LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KICAgIGRlYWRsaW5lID0gdGltZS50aW1l
  >> "!B64TMP!" echo KCkgKyB0aW1lb3V0CiAgICB3aGlsZSBUcnVlOgogICAgICAgIHRyeToKICAgICAgICAgICAgZGF0
  >> "!B64TMP!" echo YSA9IGZjLmNhbGwoIi92MS9jcmF3bC8iICsgc3RyKGNyYXdsX2lkKSwgbWV0aG9kPSJHRVQiKQog
  >> "!B64TMP!" echo ICAgICAgIGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgICAgIHByaW50KGYiQ1JBV0wg
  >> "!B64TMP!" echo RkFJTEVEIGZvciB7dXJsfTogc3RhdHVzIGNoZWNrIGZhaWxlZDoge2V9IiwKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJuIDEK
  >> "!B64TMP!" echo ICAgICAgICBzdGF0dXMgPSBzdHIoZGF0YS5nZXQoInN0YXR1cyIpIG9yICJ1bmtub3duIikKICAg
  >> "!B64TMP!" echo ICAgICBpZiBzdGF0dXMgaW4gVEVSTUlOQUwgb3IgKHN0YXR1cyBub3QgaW4KICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICgiYWN0aXZlIiwgInNjcmFwaW5nIiwgInF1ZXVlZCIsICJw
  >> "!B64TMP!" echo cm9jZXNzaW5nIiwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAid2FpdGluZyIs
  >> "!B64TMP!" echo ICJydW5uaW5nIikgYW5kIGRhdGEuZ2V0KCJkYXRhIikpOgogICAgICAgICAgICBicmVhawogICAg
  >> "!B64TMP!" echo ICAgIGlmIHRpbWUudGltZSgpID49IGRlYWRsaW5lOgogICAgICAgICAgICBwcmludChmIkNyYXds
  >> "!B64TMP!" echo IHtjcmF3bF9pZH0gc3RpbGwge2NyYXdsX3N1bW1hcnkoZGF0YSl9IGFmdGVyICIKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgZiJ7dGltZW91dH1zIOKAlCBrZWVwaW5nIHBvbGxpbmcgd2l0aDoiLCBmaWxlPXN5
  >> "!B64TMP!" echo cy5zdGRlcnIpCiAgICAgICAgICAgIHByaW50KGYiICAgIHB5dGhvbiB3ZWJfY3Jhd2xfc3RhdHVz
  >> "!B64TMP!" echo LnB5IHtjcmF3bF9pZH0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIGlmIGFzX2pzb246
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgICAgICBlbHNl
  >> "!B64TMP!" echo OgogICAgICAgICAgICAgICAgcHJpbnQoZiJDcmF3bCB7Y3Jhd2xfaWR9OiB7Y3Jhd2xfc3VtbWFy
  >> "!B64TMP!" echo eShkYXRhKX0gKHRpbWVkIG91dCkiKQogICAgICAgICAgICByZXR1cm4gMQogICAgICAgIHByaW50
  >> "!B64TMP!" echo KGYiICBjcmF3bCB7Y3Jhd2xfaWR9OiB7Y3Jhd2xfc3VtbWFyeShkYXRhKX0iLCBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgdGltZS5zbGVlcChtYXgocG9sbF9ldmVyeSwgMSkpCgogICAgaWYgYXNf
  >> "!B64TMP!" echo anNvbjoKICAgICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwIGlm
  >> "!B64TMP!" echo IHN0YXR1cyA9PSAiY29tcGxldGVkIiBlbHNlIDEKCiAgICBpZiBzdGF0dXMgIT0gImNvbXBsZXRl
  >> "!B64TMP!" echo ZCI6CiAgICAgICAgcHJpbnQoZiJDUkFXTCBGQUlMRUQgZm9yIHt1cmx9OiBjcmF3bCB7Y3Jhd2xf
  >> "!B64TMP!" echo aWR9IGVuZGVkIGFzICIKICAgICAgICAgICAgICBmIlwie3N0YXR1c31cIi4iLCBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKVs6ODAwXSwgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgIHJldHVybiAxCgogICAgY3JlZGl0cyA9IGRhdGEuZ2V0KCJjcmVkaXRzVXNl
  >> "!B64TMP!" echo ZCIpCiAgICBzdWZmaXggPSBmIiwge2NyZWRpdHN9IGNyZWRpdHMgdXNlZCIgaWYgY3JlZGl0cyBp
  >> "!B64TMP!" echo cyBub3QgTm9uZSBlbHNlICIiCiAgICBwcmludChmIkNyYXdsIHtjcmF3bF9pZH06IHtjcmF3bF9z
  >> "!B64TMP!" echo dW1tYXJ5KGRhdGEpfXtzdWZmaXh9IikKICAgIHByaW50X3BhZ2VzKGRhdGEsIG1heF9wYWdlcywg
  >> "!B64TMP!" echo bWF4X2NoYXJzKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAg
  >> "!B64TMP!" echo c3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_crawl.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_crawl_status.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_crawl_status.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_crawl_status.py" "!TARGET!\local-web-search\scripts\web_crawl_status.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_crawl_status.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_crawl_status.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1135706177.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZXQgdGhlIHN0YXR1cywgcHJvZ3Jlc3MsIGFuZCBh
  >> "!B64TMP!" echo dmFpbGFibGUgcmVzdWx0cyBvZiBhbiBleGlzdGluZyBGaXJlY3Jhd2wKY3Jhd2wgKHRoZSBmaXJl
  >> "!B64TMP!" echo Y3Jhd2xfY2hlY2tfY3Jhd2xfc3RhdHVzIE1DUCB0b29sKS4KClVzYWdlOgogICAgcHl0aG9uIHdl
  >> "!B64TMP!" echo Yl9jcmF3bF9zdGF0dXMucHkgPGlkPiBbLS1tYXgtcGFnZXMgTl0gWy0tbWF4LWNoYXJzIE5dIFst
  >> "!B64TMP!" echo LWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFj
  >> "!B64TMP!" echo aGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNj
  >> "!B64TMP!" echo cmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVf
  >> "!B64TMP!" echo c3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBm
  >> "!B64TMP!" echo YWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0
  >> "!B64TMP!" echo cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVf
  >> "!B64TMP!" echo c3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpQcmludHMgYENyYXdsIDxp
  >> "!B64TMP!" echo ZD46IDxzdGF0dXM+IChjb21wbGV0ZWQvdG90YWwgcGFnZXMpYDsgd2hlbiB0aGUgY3Jhd2wgaGFz
  >> "!B64TMP!" echo CmZpbmlzaGVkLCB0aGUgY29sbGVjdGVkIHBhZ2VzIGZvbGxvdyBhcyBgTi4gPHVybD5gICsgbWFy
  >> "!B64TMP!" echo a2Rvd24gdHJ1bmNhdGVkIGF0Ci0tbWF4LWNoYXJzIGNoYXJzIChkZWZhdWx0IDIwMDA7IHVwIHRv
  >> "!B64TMP!" echo IC0tbWF4LXBhZ2VzIHBhZ2VzLCBkZWZhdWx0IDI1KS4KYC0tanNvbmAgcHJpbnRzIHRoZSByYXcg
  >> "!B64TMP!" echo QVBJIHJlc3BvbnNlIGluc3RlYWQuIFRoZSBzdGF0dXMgcXVlcnkgaXRzZWxmIG9ubHkKZmFpbHMg
  >> "!B64TMP!" echo KGV4aXQgMSkgd2hlbiB0aGUgQVBJIGNhbm5vdCBiZSByZWFjaGVkOyBhIGBmYWlsZWRgIGNyYXds
  >> "!B64TMP!" echo IHN0aWxsIGV4aXRzIDAuCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lz
  >> "!B64TMP!" echo LnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18p
  >> "!B64TMP!" echo KSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAg
  >> "!B64TMP!" echo Y2xpZW50ICsgc2VsZi1oZWFsCmltcG9ydCB3ZWJfY3Jhd2wgICMgc2libGluZzogc2hhcmVkIGNy
  >> "!B64TMP!" echo YXdsIG91dHB1dCBmb3JtYXR0aW5nCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL2NyYXdsIikKCgpk
  >> "!B64TMP!" echo ZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBhcmdz
  >> "!B64TMP!" echo IG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdlYl9j
  >> "!B64TMP!" echo cmF3bF9zdGF0dXMucHkgPGlkPiBbLS1tYXgtcGFnZXMgTl0gWy0tbWF4LWNoYXJzIE5dICIKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAiWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIK
  >> "!B64TMP!" echo ICAgIGNyYXdsX2lkID0gYXJnc1swXQogICAgbWF4X3BhZ2VzLCBtYXhfY2hhcnMsIGFzX2pzb24g
  >> "!B64TMP!" echo PSAyNSwgMjAwMCwgRmFsc2UKICAgIGkgPSAxCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAg
  >> "!B64TMP!" echo ICAgIGEgPSBhcmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1tYXgtcGFnZXMiIGFuZCBpICsgMSA8
  >> "!B64TMP!" echo IGxlbihhcmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIHRyeToKICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIG1heF9wYWdlcyA9IGludChhcmdzW2ldKQogICAgICAgICAgICBleGNlcHQgVmFsdWVF
  >> "!B64TMP!" echo cnJvcjoKICAgICAgICAgICAgICAgIHByaW50KGYiaW52YWxpZCAtLW1heC1wYWdlczoge2FyZ3Nb
  >> "!B64TMP!" echo aV19IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBl
  >> "!B64TMP!" echo bGlmIGEgPT0gIi0tbWF4LWNoYXJzIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAg
  >> "!B64TMP!" echo IGkgKz0gMQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQo
  >> "!B64TMP!" echo YXJnc1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBw
  >> "!B64TMP!" echo cmludChmImludmFsaWQgLS1tYXgtY2hhcnM6IHthcmdzW2ldfSIsIGZpbGU9c3lzLnN0ZGVycikK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLWpzb24iOgogICAg
  >> "!B64TMP!" echo ICAgICAgICBhc19qc29uID0gVHJ1ZQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgog
  >> "!B64TMP!" echo ICAgICAgICAgICBwcmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcHJpbnQoZiJ1
  >> "!B64TMP!" echo bmV4cGVjdGVkIGFyZ3VtZW50OiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJl
  >> "!B64TMP!" echo dHVybiAyCiAgICAgICAgaSArPSAxCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIv
  >> "!B64TMP!" echo djEvY3Jhd2wvIiArIHN0cihjcmF3bF9pZCksIG1ldGhvZD0iR0VUIikKICAgIGV4Y2VwdCBmYy5G
  >> "!B64TMP!" echo Y0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJDUkFXTCBTVEFUVVMgRkFJTEVEIGZvciB7Y3Jh
  >> "!B64TMP!" echo d2xfaWR9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAg
  >> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAg
  >> "!B64TMP!" echo IGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gMAoKICAgIHByaW50KGYiQ3Jhd2wge2NyYXdsX2lkfToge3dlYl9jcmF3bC5jcmF3bF9zdW1t
  >> "!B64TMP!" echo YXJ5KGRhdGEpfSIpCiAgICB3ZWJfY3Jhd2wucHJpbnRfcGFnZXMoZGF0YSwgbWF4X3BhZ2VzLCBt
  >> "!B64TMP!" echo YXhfY2hhcnMpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBz
  >> "!B64TMP!" echo eXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_crawl_status.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_agent.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_agent.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_agent.py" "!TARGET!\local-web-search\scripts\web_agent.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_agent.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_agent.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3756143307.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTdGFydCBhbiBhc3luY2hyb25vdXMgRmlyZWNyYXds
  >> "!B64TMP!" echo IHJlc2VhcmNoIGFnZW50IGpvYiAodGhlIGZpcmVjcmF3bF9hZ2VudApNQ1AgdG9vbCk6IGdpdmUg
  >> "!B64TMP!" echo aXQgYSBwcm9tcHQsIG9wdGlvbmFsIHNlZWQgVVJMcywgYW5kIHJlYWQgdGhlIHJlc3VsdCBsYXRl
  >> "!B64TMP!" echo cgp3aXRoIHdlYl9hZ2VudF9zdGF0dXMucHkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJfYWdlbnQu
  >> "!B64TMP!" echo cHkgIjxwcm9tcHQ+IiBbc2VlZF91cmwgLi4uXSBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0
  >> "!B64TMP!" echo aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRo
  >> "!B64TMP!" echo ZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMg
  >> "!B64TMP!" echo dGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJl
  >> "!B64TMP!" echo dHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRy
  >> "!B64TMP!" echo YW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYu
  >> "!B64TMP!" echo CllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1
  >> "!B64TMP!" echo biB0aGUgc2NyaXB0LgoKVGhlIGZpcnN0IGFyZ3VtZW50IGlzIHRoZSByZXNlYXJjaCBwcm9tcHQg
  >> "!B64TMP!" echo KHF1b3RlIGl0KTsgYW55IGZ1cnRoZXIgcG9zaXRpb25hbAphcmd1bWVudHMgYXJlIHNlZWQgVVJM
  >> "!B64TMP!" echo cyB0aGUgYWdlbnQgc2hvdWxkIHN0YXJ0IGZyb20uIFRoaXMgY2FsbCBvbmx5IFNUQVJUUwp0aGUg
  >> "!B64TMP!" echo am9iIGFuZCBwcmludHMgaXRzIElEIOKAlCB0aGUgcmVzZWFyY2ggaXRzZWxmIGNvbW1vbmx5IHRh
  >> "!B64TMP!" echo a2VzIHNldmVyYWwKbWludXRlcywgc28gcG9sbCB0aGUgam9iIHVudGlsIGl0IGlzIGNvbXBsZXRl
  >> "!B64TMP!" echo ZCBvciBmYWlsZWQ6CgogICAgcHl0aG9uIHdlYl9hZ2VudF9zdGF0dXMucHkgPGlkPgoKYC0tanNv
  >> "!B64TMP!" echo bmAgcHJpbnRzIHRoZSByYXcgQVBJIHJlc3BvbnNlIGluc3RlYWQgb2YgdGhlIHN1bW1hcnkuCiIi
  >> "!B64TMP!" echo IgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9z
  >> "!B64TMP!" echo LnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3
  >> "!B64TMP!" echo bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFs
  >> "!B64TMP!" echo CgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL2FnZW50IikKCgpkZWYgbWFpbigpIC0+IGludDoKICAg
  >> "!B64TMP!" echo IGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBhcmdzIG9yIGFyZ3NbMF0uc3RhcnRzd2l0
  >> "!B64TMP!" echo aCgiLS0iKToKICAgICAgICBwcmludCgndXNhZ2U6IHdlYl9hZ2VudC5weSAiPHByb21wdD4iIFtz
  >> "!B64TMP!" echo ZWVkX3VybCAuLi5dIFstLWpzb25dJywKICAgICAgICAgICAgICBmaWxlPXN5cy5zdGRlcnIpCiAg
  >> "!B64TMP!" echo ICAgICAgcmV0dXJuIDIKICAgIHByb21wdCA9IGFyZ3NbMF0KICAgIHVybHMsIGFzX2pzb24gPSBb
  >> "!B64TMP!" echo XSwgRmFsc2UKICAgIGkgPSAxCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAgICAgIGEgPSBh
  >> "!B64TMP!" echo cmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1qc29uIjoKICAgICAgICAgICAgYXNfanNvbiA9IFRy
  >> "!B64TMP!" echo dWUKICAgICAgICBlbGlmIGEuc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICAgICAgcHJpbnQoZiJ1
  >> "!B64TMP!" echo bmtub3duIG9wdGlvbjoge2F9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo MgogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHVybHMuYXBwZW5kKGEpCiAgICAgICAgaSArPSAx
  >> "!B64TMP!" echo CgogICAgYm9keSA9IHsicHJvbXB0IjogcHJvbXB0fQogICAgaWYgdXJsczoKICAgICAgICBib2R5
  >> "!B64TMP!" echo WyJ1cmxzIl0gPSB1cmxzCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIvdjEvYWdl
  >> "!B64TMP!" echo bnQiLCBtZXRob2Q9IlBPU1QiLCBib2R5PWJvZHkpCiAgICBleGNlcHQgZmMuRmNFcnJvciBhcyBl
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KGYiQUdFTlQgU1RBUlQgRkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRl
  >> "!B64TMP!" echo cnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo anNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAoKICAgIHBheWxvYWQgPSBkYXRhLmdl
  >> "!B64TMP!" echo dCgiZGF0YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRh
  >> "!B64TMP!" echo CiAgICBqb2JfaWQgPSBwYXlsb2FkLmdldCgiaWQiKSBvciBkYXRhLmdldCgiaWQiKQogICAgaWYg
  >> "!B64TMP!" echo bm90IGpvYl9pZDoKICAgICAgICBwcmludCgiQUdFTlQgU1RBUlQgRkFJTEVEOiB0aGUgQVBJIGRp
  >> "!B64TMP!" echo ZCBub3QgcmV0dXJuIGEgam9iIGlkLiBSZXNwb25zZToiLAogICAgICAgICAgICAgIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICBwcmludChqc29uLmR1bXBzKGRhdGEpWzo4MDBdLCBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgcmV0dXJuIDEKICAgIHByaW50KGYiQWdlbnQgam9iIHN0YXJ0ZWQ6IHtq
  >> "!B64TMP!" echo b2JfaWR9IikKICAgIGlmIHVybHM6CiAgICAgICAgcHJpbnQoZiJTZWVkIFVSTHM6IHsnLCAnLmpv
  >> "!B64TMP!" echo aW4odXJscyl9IikKICAgIHByaW50KCJSZXNlYXJjaCBjb21tb25seSB0YWtlcyBzZXZlcmFsIG1p
  >> "!B64TMP!" echo bnV0ZXMg4oCUIHBvbGwgd2l0aDoiKQogICAgcHJpbnQoZiIgICAgcHl0aG9uIHdlYl9hZ2VudF9z
  >> "!B64TMP!" echo dGF0dXMucHkge2pvYl9pZH0iKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWlu
  >> "!B64TMP!" echo X18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_agent.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_agent_status.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_agent_status.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_agent_status.py" "!TARGET!\local-web-search\scripts\web_agent_status.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_agent_status.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_agent_status.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1276902308.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJHZXQgdGhlIHByb2dyZXNzIG9yIGZpbmFsIHJlc3Vs
  >> "!B64TMP!" echo dHMgb2YgYSBGaXJlY3Jhd2wgcmVzZWFyY2ggYWdlbnQgam9iICh0aGUKZmlyZWNyYXdsX2FnZW50
  >> "!B64TMP!" echo X3N0YXR1cyBNQ1AgdG9vbCksIHN0YXJ0ZWQgd2l0aCB3ZWJfYWdlbnQucHkuCgpVc2FnZToKICAg
  >> "!B64TMP!" echo IHB5dGhvbiB3ZWJfYWdlbnRfc3RhdHVzLnB5IDxpZD4gWy0tanNvbl0KClNlbGYtaGVhbGluZzog
  >> "!B64TMP!" echo aWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBv
  >> "!B64TMP!" echo ciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3Rh
  >> "!B64TMP!" echo cnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFu
  >> "!B64TMP!" echo ZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVzCnNlbGYtaGVhbCBvbmNl
  >> "!B64TMP!" echo OyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdpdGggYSBzaG9ydCBiYWNr
  >> "!B64TMP!" echo b2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5weSBmaXJzdCDigJQganVz
  >> "!B64TMP!" echo dCBydW4gdGhlIHNjcmlwdC4KClByaW50cyBgQWdlbnQgPGlkPjogPHN0YXR1cz5gLiBBIGBwcm9j
  >> "!B64TMP!" echo ZXNzaW5nYC9gYWN0aXZlYCBzdGF0dXMgaXMgbm9uLXRlcm1pbmFsCuKAlCBjaGVjayBhZ2FpbiBh
  >> "!B64TMP!" echo ZnRlciAxNS0zMCBzLiBXaGVuIHRoZSBqb2IgaXMgYGNvbXBsZXRlZGAsIHRoZSByZXNlYXJjaCBy
  >> "!B64TMP!" echo ZXN1bHQKZm9sbG93cyAoc3RlcHMsIHNvdXJjZXMsIGFuZCB0aGUgZmluYWwgYW5zd2VyL3JlcG9y
  >> "!B64TMP!" echo dCBhcyByZXR1cm5lZCBieSB0aGUgQVBJKTsKYGZhaWxlZGAgam9icyBwcmludCB0aGUgYXZhaWxh
  >> "!B64TMP!" echo YmxlIGVycm9yIGRldGFpbHMgYW5kIGV4aXQgMS4gYC0tanNvbmAgcHJpbnRzCnRoZSByYXcgQVBJ
  >> "!B64TMP!" echo IHJlc3BvbnNlIGluc3RlYWQuCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoK
  >> "!B64TMP!" echo c3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxl
  >> "!B64TMP!" echo X18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhU
  >> "!B64TMP!" echo VFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL2FnZW50IikKCgpk
  >> "!B64TMP!" echo ZWYgcHJpbnRfcmVzdWx0KHJlc3VsdCwgaW5kZW50PTApOgogICAgIiIiUmVjdXJzaXZlbHkgcHJp
  >> "!B64TMP!" echo bnQgdGhlIGFnZW50IHJlc3VsdCBpbiBhIHJlYWRhYmxlIG91dGxpbmUuIiIiCiAgICBwYWQgPSAi
  >> "!B64TMP!" echo ICIgKiBpbmRlbnQKICAgIGlmIGlzaW5zdGFuY2UocmVzdWx0LCBkaWN0KToKICAgICAgICBmb3Ig
  >> "!B64TMP!" echo a2V5LCB2YWwgaW4gcmVzdWx0Lml0ZW1zKCk6CiAgICAgICAgICAgIGlmIGlzaW5zdGFuY2UodmFs
  >> "!B64TMP!" echo LCAoZGljdCwgbGlzdCkpOgogICAgICAgICAgICAgICAgcHJpbnQoZiJ7cGFkfXtrZXl9OiIpCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICBwcmludF9yZXN1bHQodmFsLCBpbmRlbnQgKyAyKQogICAgICAgICAgICBl
  >> "!B64TMP!" echo bHNlOgogICAgICAgICAgICAgICAgdGV4dCA9IHN0cih2YWwpCiAgICAgICAgICAgICAgICBpZiBs
  >> "!B64TMP!" echo ZW4odGV4dCkgPiA0MDAwOgogICAgICAgICAgICAgICAgICAgIHRleHQgPSB0ZXh0Wzo0MDAwXSAr
  >> "!B64TMP!" echo IGYiXG57cGFkfVsuLi4gdHJ1bmNhdGVkIC4uLl0iCiAgICAgICAgICAgICAgICBwcmludChmIntw
  >> "!B64TMP!" echo YWR9e2tleX06IHt0ZXh0fSIpCiAgICBlbGlmIGlzaW5zdGFuY2UocmVzdWx0LCBsaXN0KToKICAg
  >> "!B64TMP!" echo ICAgICBmb3IgbiwgaXRlbSBpbiBlbnVtZXJhdGUocmVzdWx0LCAxKToKICAgICAgICAgICAgcHJp
  >> "!B64TMP!" echo bnQoZiJ7cGFkfXtufS4iKQogICAgICAgICAgICBwcmludF9yZXN1bHQoaXRlbSwgaW5kZW50ICsg
  >> "!B64TMP!" echo MikKICAgIGVsc2U6CiAgICAgICAgdGV4dCA9IHN0cihyZXN1bHQpCiAgICAgICAgaWYgbGVuKHRl
  >> "!B64TMP!" echo eHQpID4gNDAwMDoKICAgICAgICAgICAgdGV4dCA9IHRleHRbOjQwMDBdICsgZiJcbntwYWR9Wy4u
  >> "!B64TMP!" echo LiB0cnVuY2F0ZWQgLi4uXSIKICAgICAgICBwcmludChwYWQgKyB0ZXh0KQoKCmRlZiBtYWluKCkg
  >> "!B64TMP!" echo LT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mgb3IgYXJnc1sw
  >> "!B64TMP!" echo XS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX2FnZW50X3N0YXR1
  >> "!B64TMP!" echo cy5weSA8aWQ+IFstLWpzb25dIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCiAg
  >> "!B64TMP!" echo ICBqb2JfaWQgPSBhcmdzWzBdCiAgICBhc19qc29uID0gIi0tanNvbiIgaW4gYXJnc1sxOl0KCiAg
  >> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNhbGwoIi92MS9hZ2VudC8iICsgc3RyKGpvYl9pZCks
  >> "!B64TMP!" echo IG1ldGhvZD0iR0VUIikKICAgIGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo ZiJBR0VOVCBTVEFUVVMgRkFJTEVEIGZvciB7am9iX2lkfToge2V9IiwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgICAgIGlmIGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxlPXN5cy5z
  >> "!B64TMP!" echo dGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAgICAgIHByaW50KGpz
  >> "!B64TMP!" echo b24uZHVtcHMoZGF0YSkpCiAgICAgICAgcmV0dXJuIDAgaWYgZGF0YS5nZXQoInN0YXR1cyIpICE9
  >> "!B64TMP!" echo ICJmYWlsZWQiIGVsc2UgMQoKICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0YSIpIGlmIGlzaW5z
  >> "!B64TMP!" echo dGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRhCiAgICBzdGF0dXMgPSBzdHIo
  >> "!B64TMP!" echo cGF5bG9hZC5nZXQoInN0YXR1cyIpIG9yIGRhdGEuZ2V0KCJzdGF0dXMiKSBvciAidW5rbm93biIp
  >> "!B64TMP!" echo CiAgICBwcmludChmIkFnZW50IHtqb2JfaWR9OiB7c3RhdHVzfSIpCiAgICBpZiBzdGF0dXMgbm90
  >> "!B64TMP!" echo IGluICgiY29tcGxldGVkIiwgImZhaWxlZCIsICJjYW5jZWxsZWQiLCAic3RvcHBlZCIpOgogICAg
  >> "!B64TMP!" echo ICAgIHByaW50KCIobm9uLXRlcm1pbmFsIOKAlCBjaGVjayBhZ2FpbiBhZnRlciAxNS0zMCBzKSIp
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIDAKICAgIHJlc3VsdCA9IHBheWxvYWQuZ2V0KCJyZXN1bHQiKQogICAg
  >> "!B64TMP!" echo aWYgcmVzdWx0IGlzIE5vbmU6CiAgICAgICAgcmVzdWx0ID0gZGF0YS5nZXQoInJlc3VsdCIpCiAg
  >> "!B64TMP!" echo ICBpZiByZXN1bHQgaXMgbm90IE5vbmU6CiAgICAgICAgcHJpbnQoKQogICAgICAgIHByaW50X3Jl
  >> "!B64TMP!" echo c3VsdChyZXN1bHQpCiAgICBlbGlmIHN0YXR1cyA9PSAiZmFpbGVkIjoKICAgICAgICBlcnJvciA9
  >> "!B64TMP!" echo IHBheWxvYWQuZ2V0KCJlcnJvciIpIG9yIGRhdGEuZ2V0KCJlcnJvciIpCiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo ZiJlcnJvcjoge2Vycm9yIG9yICcobm8gZGV0YWlscyByZXR1cm5lZCknfSIpCiAgICByZXR1cm4g
  >> "!B64TMP!" echo MCBpZiBzdGF0dXMgPT0gImNvbXBsZXRlZCIgZWxzZSAxCgoKaWYgX19uYW1lX18gPT0gIl9fbWFp
  >> "!B64TMP!" echo bl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_agent_status.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_interact.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_interact.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_interact.py" "!TARGET!\local-web-search\scripts\web_interact.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_interact.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_interact.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS487167018.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJJbnRlcmFjdCB3aXRoIGEgc2NyYXBlZCBwYWdlIHRo
  >> "!B64TMP!" echo cm91Z2ggYSBsaXZlIEZpcmVjcmF3bCBicm93c2VyIHNlc3Npb24KKHRoZSBmaXJlY3Jhd2xfaW50
  >> "!B64TMP!" echo ZXJhY3QgTUNQIHRvb2wpOiBuYXZpZ2F0ZSwgY2xpY2sgY29udHJvbHMsIGZpbGwgZmllbGRzLCBv
  >> "!B64TMP!" echo cgpydW4gYnJvd3NlciBjb2RlLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2ludGVyYWN0LnB5ICgt
  >> "!B64TMP!" echo LXNjcmFwZS1pZCBJRCB8IC0tdXJsIFVSTCkKICAgICAgICAgICAgICAgICAgICAgICAgICAgKC0t
  >> "!B64TMP!" echo cHJvbXB0IFRFWFQgfCAtLWNvZGUgVEVYVCBbLS1sYW5ndWFnZSBiYXNofHB5dGhvbnxub2RlXSkK
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgWy0tdGltZW91dCBTXSBbLS1qc29uXQoKU2VsZi1o
  >> "!B64TMP!" echo ZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIg
  >> "!B64TMP!" echo ZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGlj
  >> "!B64TMP!" echo YWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVu
  >> "!B64TMP!" echo LmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1o
  >> "!B64TMP!" echo ZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNo
  >> "!B64TMP!" echo b3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0
  >> "!B64TMP!" echo IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJvdmlkZSBFSVRIRVIgLS1zY3JhcGUtaWQgKHJl
  >> "!B64TMP!" echo dXNlIGEgcHJldmlvdXMgc2NyYXBlJ3Mgc2Vzc2lvbikgb3IgLS11cmwKKG9wZW4gYSBmcmVzaCBz
  >> "!B64TMP!" echo ZXNzaW9uKSwgYW5kIEVJVEhFUiAtLXByb21wdCAobmF0dXJhbC1sYW5ndWFnZSBpbnN0cnVjdGlv
  >> "!B64TMP!" echo bnMpCm9yIC0tY29kZSAod2l0aCAtLWxhbmd1YWdlLCBkZWZhdWx0IGJhc2gpLiBOT1RFOiB0aGlz
  >> "!B64TMP!" echo IGFjdHMgb24gdGhlIExJVkUgc2l0ZSDigJQKYWN0aW9ucyBzdWNoIGFzIGZvcm0gc3VibWlzc2lv
  >> "!B64TMP!" echo biBjYW4gY3JlYXRlIHBlcnNpc3RlbnQgZXh0ZXJuYWwgc2lkZSBlZmZlY3RzLgoKUHJpbnRzIHRo
  >> "!B64TMP!" echo ZSBBUEkncyBKU09OIHJlc3BvbnNlOiBleGVjdXRpb24gb3V0cHV0LCBzdGRvdXQvc3RkZXJyLCBl
  >> "!B64TMP!" echo eGl0CnN0YXR1cywgYW5kIHRoZSBzZXNzaW9uIHZpZXdpbmcgVVJMcy4gYC0tanNvbmAgcHJpbnRz
  >> "!B64TMP!" echo IGl0IGNvbXBhY3Qgb24gb25lIGxpbmUKaW5zdGVhZCBvZiBwcmV0dHktcHJpbnRlZC4KIiIiCmlt
  >> "!B64TMP!" echo cG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0
  >> "!B64TMP!" echo aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXdsX2Fw
  >> "!B64TMP!" echo aSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwKCkVO
  >> "!B64TMP!" echo RFBPSU5UID0gZmMudXJsKCIvdjEvaW50ZXJhY3QiKQoKTEFOR1VBR0VTID0gKCJiYXNoIiwgInB5
  >> "!B64TMP!" echo dGhvbiIsICJub2RlIikKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsx
  >> "!B64TMP!" echo Ol0KICAgIHNjcmFwZV9pZCwgdXJsID0gTm9uZSwgTm9uZQogICAgcHJvbXB0LCBjb2RlLCBsYW5n
  >> "!B64TMP!" echo dWFnZSA9IE5vbmUsIE5vbmUsIE5vbmUKICAgIHRpbWVvdXQsIGFzX2pzb24gPSBOb25lLCBGYWxz
  >> "!B64TMP!" echo ZQogICAgaSA9IDAKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0K
  >> "!B64TMP!" echo ICAgICAgICBpZiBhID09ICItLXNjcmFwZS1pZCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAg
  >> "!B64TMP!" echo ICAgICAgICBpICs9IDEKICAgICAgICAgICAgc2NyYXBlX2lkID0gYXJnc1tpXQogICAgICAgIGVs
  >> "!B64TMP!" echo aWYgYSA9PSAiLS11cmwiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAgICAgaSArPSAx
  >> "!B64TMP!" echo CiAgICAgICAgICAgIHVybCA9IGFyZ3NbaV0KICAgICAgICBlbGlmIGEgPT0gIi0tcHJvbXB0IiBh
  >> "!B64TMP!" echo bmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICBwcm9t
  >> "!B64TMP!" echo cHQgPSBhcmdzW2ldCiAgICAgICAgZWxpZiBhID09ICItLWNvZGUiIGFuZCBpICsgMSA8IGxlbihh
  >> "!B64TMP!" echo cmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIGNvZGUgPSBhcmdzW2ldCiAgICAg
  >> "!B64TMP!" echo ICAgZWxpZiBhID09ICItLWxhbmd1YWdlIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGkgKz0gMQogICAgICAgICAgICBsYW5ndWFnZSA9IGFyZ3NbaV0KICAgICAgICAgICAgaWYg
  >> "!B64TMP!" echo bGFuZ3VhZ2Ugbm90IGluIExBTkdVQUdFUzoKICAgICAgICAgICAgICAgIHByaW50KGYiaW52YWxp
  >> "!B64TMP!" echo ZCAtLWxhbmd1YWdlOiB7bGFuZ3VhZ2V9ICIKICAgICAgICAgICAgICAgICAgICAgIGYiKG9uZSBv
  >> "!B64TMP!" echo ZiB7JywgJy5qb2luKExBTkdVQUdFUyl9KSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLXRpbWVvdXQiIGFuZCBpICsgMSA8IGxl
  >> "!B64TMP!" echo bihhcmdzKToKICAgICAgICAgICAgaSArPSAxCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgIHRpbWVvdXQgPSBpbnQoYXJnc1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICBwcmludChmImludmFsaWQgLS10aW1lb3V0OiB7YXJnc1tpXX0iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGVsaWYgYSA9
  >> "!B64TMP!" echo PSAiLS1qc29uIjoKICAgICAgICAgICAgYXNfanNvbiA9IFRydWUKICAgICAgICBlbGlmIGEuc3Rh
  >> "!B64TMP!" echo cnRzd2l0aCgiLS0iKToKICAgICAgICAgICAgcHJpbnQoZiJ1bmtub3duIG9wdGlvbjoge2F9Iiwg
  >> "!B64TMP!" echo ZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGVsc2U6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHByaW50KGYidW5leHBlY3RlZCBhcmd1bWVudDoge2F9IiwgZmlsZT1zeXMuc3RkZXJy
  >> "!B64TMP!" echo KQogICAgICAgICAgICByZXR1cm4gMgogICAgICAgIGkgKz0gMQoKICAgIGlmIGJvb2woc2NyYXBl
  >> "!B64TMP!" echo X2lkKSA9PSBib29sKHVybCk6CiAgICAgICAgcHJpbnQoInByb3ZpZGUgZXhhY3RseSBvbmUgb2Yg
  >> "!B64TMP!" echo LS1zY3JhcGUtaWQgKHJldXNlIGEgc2NyYXBlJ3Mgc2Vzc2lvbikgIgogICAgICAgICAgICAgICJv
  >> "!B64TMP!" echo ciAtLXVybCAob3BlbiBhIG5ldyBzZXNzaW9uKSwgbm90IGJvdGgiLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIDIKICAgIGlmIG5vdCBwcm9tcHQgYW5kIG5vdCBjb2RlOgogICAgICAg
  >> "!B64TMP!" echo IHByaW50KCJwcm92aWRlIGVpdGhlciAtLXByb21wdCAobmF0dXJhbCBsYW5ndWFnZSkgb3IgLS1j
  >> "!B64TMP!" echo b2RlICIKICAgICAgICAgICAgICAiKGV4ZWN1dGFibGUsIHdpdGggLS1sYW5ndWFnZSkiLCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKICAgIGlmIGxhbmd1YWdlIGFuZCBub3QgY29k
  >> "!B64TMP!" echo ZToKICAgICAgICBwcmludCgiLS1sYW5ndWFnZSBjYW4gb25seSBiZSB1c2VkIHRvZ2V0aGVyIHdp
  >> "!B64TMP!" echo dGggLS1jb2RlIiwKICAgICAgICAgICAgICBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IDIKCiAgICBib2R5ID0ge30KICAgIGlmIHNjcmFwZV9pZDoKICAgICAgICBib2R5WyJzY3JhcGVJ
  >> "!B64TMP!" echo ZCJdID0gc2NyYXBlX2lkCiAgICBlbHNlOgogICAgICAgIGJvZHlbInVybCJdID0gdXJsCiAgICBp
  >> "!B64TMP!" echo ZiBwcm9tcHQ6CiAgICAgICAgYm9keVsicHJvbXB0Il0gPSBwcm9tcHQKICAgIGlmIGNvZGU6CiAg
  >> "!B64TMP!" echo ICAgICAgYm9keVsiY29kZSJdID0gY29kZQogICAgICAgIGJvZHlbImxhbmd1YWdlIl0gPSBsYW5n
  >> "!B64TMP!" echo dWFnZSBvciAiYmFzaCIKICAgIGlmIHRpbWVvdXQgaXMgbm90IE5vbmU6CiAgICAgICAgYm9keVsi
  >> "!B64TMP!" echo dGltZW91dCJdID0gdGltZW91dAoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3Yx
  >> "!B64TMP!" echo L2ludGVyYWN0IiwgbWV0aG9kPSJQT1NUIiwgYm9keT1ib2R5KQogICAgZXhjZXB0IGZjLkZjRXJy
  >> "!B64TMP!" echo b3IgYXMgZToKICAgICAgICBwcmludChmIklOVEVSQUNUIEZBSUxFRDoge2V9IiwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIGlmIGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBwcmludChqc29uLmR1bXBzKGRhdGEp
  >> "!B64TMP!" echo IGlmIGFzX2pzb24gZWxzZSBqc29uLmR1bXBzKGRhdGEsIGluZGVudD0yKSkKICAgIHJldHVybiAw
  >> "!B64TMP!" echo CgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_interact.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_interact_stop.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_interact_stop.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_interact_stop.py" "!TARGET!\local-web-search\scripts\web_interact_stop.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_interact_stop.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_interact_stop.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS640213521.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTdG9wIHRoZSBsaXZlIEZpcmVjcmF3bCBpbnRlcmFj
  >> "!B64TMP!" echo dCBzZXNzaW9uIGZvciBhIHNjcmFwZUlkIGFuZCByZWxlYXNlIGl0cwpyZXNvdXJjZXMgKHRoZSBm
  >> "!B64TMP!" echo aXJlY3Jhd2xfaW50ZXJhY3Rfc3RvcCBNQ1AgdG9vbCkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
  >> "!B64TMP!" echo aW50ZXJhY3Rfc3RvcC5weSA8c2NyYXBlSWQ+IFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRo
  >> "!B64TMP!" echo ZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhl
  >> "!B64TMP!" echo CmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0
  >> "!B64TMP!" echo aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0
  >> "!B64TMP!" echo cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJh
  >> "!B64TMP!" echo bnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4K
  >> "!B64TMP!" echo WW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVu
  >> "!B64TMP!" echo IHRoZSBzY3JpcHQuCgpQcmludHMgYSBjb25maXJtYXRpb24gKHBsdXMgdGhlIEFQSSdzIHJlc3Bv
  >> "!B64TMP!" echo bnNlIGJvZHkgd2hlbiBvbmUgaXMgcmV0dXJuZWQpLgpgLS1qc29uYCBwcmludHMgdGhlIHJhdyBB
  >> "!B64TMP!" echo UEkgcmVzcG9uc2UgaW5zdGVhZC4gVGhlIHNlc3Npb24gY2Fubm90IGJlIHJlc3VtZWQKYWZ0ZXIg
  >> "!B64TMP!" echo aXQgaXMgc3RvcHBlZC4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMu
  >> "!B64TMP!" echo cGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykp
  >> "!B64TMP!" echo KQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBj
  >> "!B64TMP!" echo bGllbnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvaW50ZXJhY3QiKQoKCmRl
  >> "!B64TMP!" echo ZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAgaWYgbm90IGFyZ3Mg
  >> "!B64TMP!" echo b3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX2lu
  >> "!B64TMP!" echo dGVyYWN0X3N0b3AucHkgPHNjcmFwZUlkPiBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gMgogICAgc2NyYXBlX2lkID0gYXJnc1swXQogICAgYXNfanNvbiA9ICItLWpz
  >> "!B64TMP!" echo b24iIGluIGFyZ3NbMTpdCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIvdjEvaW50
  >> "!B64TMP!" echo ZXJhY3QvIiArIHN0cihzY3JhcGVfaWQpICsgIi9zdG9wIiwKICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICBtZXRob2Q9IlBPU1QiKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChmIklOVEVSQUNUIFNUT1AgRkFJTEVEIGZvciB7c2NyYXBlX2lkfToge2V9IiwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIGlmIGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxl
  >> "!B64TMP!" echo PXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAgICAgIHBy
  >> "!B64TMP!" echo aW50KGpzb24uZHVtcHMoZGF0YSkpCiAgICAgICAgcmV0dXJuIDAKICAgIHByaW50KGYiSW50ZXJh
  >> "!B64TMP!" echo Y3Qgc2Vzc2lvbiB7c2NyYXBlX2lkfSBzdG9wcGVkLiIpCiAgICBpZiBkYXRhOgogICAgICAgIHBy
  >> "!B64TMP!" echo aW50KGpzb24uZHVtcHMoZGF0YSwgaW5kZW50PTIpKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVf
  >> "!B64TMP!" echo XyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_interact_stop.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_parse.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_parse.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_parse.py" "!TARGET!\local-web-search\scripts\web_parse.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_parse.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_parse.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1646618542.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJQYXJzZSBhIGxvY2FsIGRvY3VtZW50IGludG8gbWFy
  >> "!B64TMP!" echo a2Rvd24gLyBIVE1MIC8gbGlua3MgLyBhIHN1bW1hcnkgLyB0YXJnZXRlZAphbnN3ZXJzIC8gc3Ry
  >> "!B64TMP!" echo dWN0dXJlZCBKU09OICh0aGUgZmlyZWNyYXdsX3BhcnNlIE1DUCB0b29sKS4gU3VwcG9ydGVkIGlu
  >> "!B64TMP!" echo cHV0cwppbmNsdWRlIGNvbW1vbiBIVE1MLCBQREYsIFdvcmQsIFJURiwgT3BlbkRvY3VtZW50LCBh
  >> "!B64TMP!" echo bmQgc3ByZWFkc2hlZXQgZmlsZXMuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJfcGFyc2UucHkgPGZp
  >> "!B64TMP!" echo bGVQYXRoPiBbLS1mb3JtYXRzIG1hcmtkb3duLGxpbmtzLC4uLl0gWy0tbWF4LWNoYXJzIE5dCiAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgIFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2Nh
  >> "!B64TMP!" echo bC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRh
  >> "!B64TMP!" echo aW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0
  >> "!B64TMP!" echo aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0
  >> "!B64TMP!" echo aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZS4gWW91IGRvIE5P
  >> "!B64TMP!" echo VCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZQpzY3Jp
  >> "!B64TMP!" echo cHQuCgpUaGUgZmlsZSBpcyB1cGxvYWRlZCB0byB0aGUgbG9jYWwgRmlyZWNyYXdsIGluc3RhbmNl
  >> "!B64TMP!" echo IChpdCBuZXZlciBsZWF2ZXMgeW91cgptYWNoaW5lKS4gYC0tZm9ybWF0c2AgdGFrZXMgYSBjb21t
  >> "!B64TMP!" echo YS1zZXBhcmF0ZWQgbGlzdCBmcm9tOiBtYXJrZG93biwgaHRtbCwKcmF3SHRtbCwgbGlua3MsIHN1
  >> "!B64TMP!" echo bW1hcnksIGpzb24sIHF1ZXJ5IChkZWZhdWx0OiBtYXJrZG93bikuIFByaW50cyB0aGUgcGFyc2Vk
  >> "!B64TMP!" echo CmNvbnRlbnQ7IHdpdGggc2V2ZXJhbCBmb3JtYXRzIGVhY2ggaXMgcHJpbnRlZCB1bmRlciBhIGAj
  >> "!B64TMP!" echo IyA8Zm9ybWF0PmAgaGVhZGVyLgpNYXJrZG93bi9IVE1MIHRydW5jYXRlIGF0IC0tbWF4LWNoYXJz
  >> "!B64TMP!" echo IGNoYXJzIChkZWZhdWx0IDIwMDAwLCBsaWtlCndlYl9zY3JhcGUucHkpLiBgLS1qc29uYCBwcmlu
  >> "!B64TMP!" echo dHMgdGhlIHJhdyBBUEkgcmVzcG9uc2UgaW5zdGVhZC4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBv
  >> "!B64TMP!" echo cwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGgu
  >> "!B64TMP!" echo YWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5n
  >> "!B64TMP!" echo OiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIv
  >> "!B64TMP!" echo djEvcGFyc2UiKQoKRk9STUFUUyA9ICgibWFya2Rvd24iLCAiaHRtbCIsICJyYXdIdG1sIiwgImxp
  >> "!B64TMP!" echo bmtzIiwgInN1bW1hcnkiLCAianNvbiIsICJxdWVyeSIpCgojIEV4dGVuc2lvbiAtPiBNSU1FIHR5
  >> "!B64TMP!" echo cGUgZm9yIHRoZSB1cGxvYWQgKGV2ZXJ5dGhpbmcgZWxzZSBpcyBzZW50IGFzIGEKIyBnZW5lcmlj
  >> "!B64TMP!" echo IG9jdGV0IHN0cmVhbSBhbmQgRmlyZWNyYXdsIHNuaWZmcyB0aGUgcmVhbCB0eXBlIHNlcnZlci1z
  >> "!B64TMP!" echo aWRlKS4KTUlNRV9UWVBFUyA9IHsKICAgICIuaHRtbCI6ICJ0ZXh0L2h0bWwiLCAiLmh0bSI6ICJ0
  >> "!B64TMP!" echo ZXh0L2h0bWwiLAogICAgIi5wZGYiOiAiYXBwbGljYXRpb24vcGRmIiwKICAgICIuZG9jIjogImFw
  >> "!B64TMP!" echo cGxpY2F0aW9uL21zd29yZCIsCiAgICAiLmRvY3giOiAiYXBwbGljYXRpb24vdm5kLm9wZW54bWxm
  >> "!B64TMP!" echo b3JtYXRzLW9mZmljZWRvY3VtZW50LndvcmRwcm9jZXNzaW5nbWwuZG9jdW1lbnQiLAogICAgIi5y
  >> "!B64TMP!" echo dGYiOiAiYXBwbGljYXRpb24vcnRmIiwKICAgICIub2R0IjogImFwcGxpY2F0aW9uL3ZuZC5vYXNp
  >> "!B64TMP!" echo cy5vcGVuZG9jdW1lbnQudGV4dCIsCiAgICAiLm9kcyI6ICJhcHBsaWNhdGlvbi92bmQub2FzaXMu
  >> "!B64TMP!" echo b3BlbmRvY3VtZW50LnNwcmVhZHNoZWV0IiwKICAgICIueGxzIjogImFwcGxpY2F0aW9uL3ZuZC5t
  >> "!B64TMP!" echo cy1leGNlbCIsCiAgICAiLnhsc3giOiAiYXBwbGljYXRpb24vdm5kLm9wZW54bWxmb3JtYXRzLW9m
  >> "!B64TMP!" echo ZmljZWRvY3VtZW50LnNwcmVhZHNoZWV0bWwuc2hlZXQiLAogICAgIi5jc3YiOiAidGV4dC9jc3Yi
  >> "!B64TMP!" echo LAogICAgIi50eHQiOiAidGV4dC9wbGFpbiIsCiAgICAiLm1kIjogInRleHQvbWFya2Rvd24iLAp9
  >> "!B64TMP!" echo CgojIEZvcm1hdHMgd2hvc2UgY29udGVudCBpcyBwbGFpbiB0ZXh0IGFuZCBjYW4gYmUgdHJ1bmNh
  >> "!B64TMP!" echo dGVkIHNhZmVseS4KVEVYVF9GT1JNQVRTID0gKCJtYXJrZG93biIsICJodG1sIiwgInJhd0h0bWwi
  >> "!B64TMP!" echo LCAic3VtbWFyeSIsICJxdWVyeSIpCgoKZGVmIGNvbnRlbnRfdHlwZV9mb3IocGF0aCk6CiAgICBy
  >> "!B64TMP!" echo ZXR1cm4gTUlNRV9UWVBFUy5nZXQob3MucGF0aC5zcGxpdGV4dChwYXRoKVsxXS5sb3dlcigpLAog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICJhcHBsaWNhdGlvbi9vY3RldC1zdHJlYW0iKQoKCmRl
  >> "!B64TMP!" echo ZiBwcmludF9maWVsZChuYW1lLCB2YWx1ZSwgbWF4X2NoYXJzKToKICAgICIiIlByaW50IG9uZSBw
  >> "!B64TMP!" echo YXJzZWQgZm9ybWF0IHVuZGVyIGEgaGVhZGVyLCB0cnVuY2F0aW5nIGxvbmcgdGV4dC4iIiIKICAg
  >> "!B64TMP!" echo IGlmIG5hbWUgIT0gIm1hcmtkb3duIjoKICAgICAgICBwcmludChmIiMjIHtuYW1lfSIpCiAgICBp
  >> "!B64TMP!" echo ZiBpc2luc3RhbmNlKHZhbHVlLCBsaXN0KToKICAgICAgICBmb3IgbiwgaXRlbSBpbiBlbnVtZXJh
  >> "!B64TMP!" echo dGUodmFsdWUsIDEpOgogICAgICAgICAgICBwcmludChmIntufS4ge2l0ZW19IikKICAgICAgICBy
  >> "!B64TMP!" echo ZXR1cm4KICAgIGlmIGlzaW5zdGFuY2UodmFsdWUsIChkaWN0LCBib29sLCBpbnQsIGZsb2F0KSk6
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyh2YWx1ZSwgaW5kZW50PTIpKQogICAgICAgIHJldHVy
  >> "!B64TMP!" echo bgogICAgdGV4dCA9IHN0cih2YWx1ZSkKICAgIGlmIG5vdCB0ZXh0OgogICAgICAgIHByaW50KCIo
  >> "!B64TMP!" echo ZW1wdHkpIikKICAgICAgICByZXR1cm4KICAgIGlmIG5hbWUgaW4gVEVYVF9GT1JNQVRTIGFuZCBs
  >> "!B64TMP!" echo ZW4odGV4dCkgPiBtYXhfY2hhcnM6CiAgICAgICAgdGV4dCA9IHRleHRbOm1heF9jaGFyc10gKyBm
  >> "!B64TMP!" echo IlxuWy4uLiB0cnVuY2F0ZWQgYXQge21heF9jaGFyc30gY2hhcnMgLi4uXSIKICAgIHByaW50KHRl
  >> "!B64TMP!" echo eHQpCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBpZiBu
  >> "!B64TMP!" echo b3QgYXJncyBvciBhcmdzWzBdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgcHJpbnQoInVzYWdl
  >> "!B64TMP!" echo OiB3ZWJfcGFyc2UucHkgPGZpbGVQYXRoPiBbLS1mb3JtYXRzIG1hcmtkb3duLGxpbmtzLC4uLl0g
  >> "!B64TMP!" echo IgogICAgICAgICAgICAgICJbLS1tYXgtY2hhcnMgTl0gWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRl
  >> "!B64TMP!" echo cnIpCiAgICAgICAgcmV0dXJuIDIKICAgIGZpbGVfcGF0aCA9IGFyZ3NbMF0KICAgIGZvcm1hdHMg
  >> "!B64TMP!" echo PSBbIm1hcmtkb3duIl0KICAgIG1heF9jaGFycywgYXNfanNvbiA9IDIwMDAwLCBGYWxzZQogICAg
  >> "!B64TMP!" echo aSA9IDEKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAg
  >> "!B64TMP!" echo ICBpZiBhID09ICItLWZvcm1hdHMiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAgICAg
  >> "!B64TMP!" echo aSArPSAxCiAgICAgICAgICAgIGZvcm1hdHMgPSBbZi5zdHJpcCgpIGZvciBmIGluIGFyZ3NbaV0u
  >> "!B64TMP!" echo c3BsaXQoIiwiKSBpZiBmLnN0cmlwKCldCiAgICAgICAgICAgIGJhZCA9IFtmIGZvciBmIGluIGZv
  >> "!B64TMP!" echo cm1hdHMgaWYgZiBub3QgaW4gRk9STUFUU10KICAgICAgICAgICAgaWYgYmFkOgogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgcHJpbnQoZiJpbnZhbGlkIC0tZm9ybWF0cyB2YWx1ZShzKTogeycsICcuam9pbihiYWQp
  >> "!B64TMP!" echo fSAiCiAgICAgICAgICAgICAgICAgICAgICBmIih2YWxpZDogeycsICcuam9pbihGT1JNQVRTKX0p
  >> "!B64TMP!" echo IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlm
  >> "!B64TMP!" echo IGEgPT0gIi0tbWF4LWNoYXJzIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkg
  >> "!B64TMP!" echo Kz0gMQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBtYXhfY2hhcnMgPSBpbnQoYXJn
  >> "!B64TMP!" echo c1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChmImludmFsaWQgLS1tYXgtY2hhcnM6IHthcmdzW2ldfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLWpzb24iOgogICAgICAg
  >> "!B64TMP!" echo ICAgICBhc19qc29uID0gVHJ1ZQogICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAg
  >> "!B64TMP!" echo ICAgICAgICBwcmludChmInVua25vd24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAg
  >> "!B64TMP!" echo ICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcHJpbnQoZiJ1bmV4
  >> "!B64TMP!" echo cGVjdGVkIGFyZ3VtZW50OiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVy
  >> "!B64TMP!" echo biAyCiAgICAgICAgaSArPSAxCgogICAgaWYgbm90IG9zLnBhdGguaXNmaWxlKGZpbGVfcGF0aCk6
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoZiJQQVJTRSBGQUlMRUQ6IG5vIHN1Y2ggZmlsZToge2ZpbGVfcGF0aH0i
  >> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKCiAgICBvcHRpb25zID0geyJmb3Jt
  >> "!B64TMP!" echo YXRzIjogZm9ybWF0c30KICAgIGZpZWxkcyA9IHsib3B0aW9ucyI6IGpzb24uZHVtcHMob3B0aW9u
  >> "!B64TMP!" echo cyksCiAgICAgICAgICAgICAgImNvbnRlbnRUeXBlIjogY29udGVudF90eXBlX2ZvcihmaWxlX3Bh
  >> "!B64TMP!" echo dGgpfQogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsX2Zvcm0oIi92MS9wYXJzZSIsIGZp
  >> "!B64TMP!" echo ZWxkcywgZmlsZV9wYXRoKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChmIlBBUlNFIEZBSUxFRCBmb3Ige2ZpbGVfcGF0aH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikK
  >> "!B64TMP!" echo ICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMuc3Rk
  >> "!B64TMP!" echo ZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChqc29u
  >> "!B64TMP!" echo LmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCgogICAgcGF5bG9hZCA9IGRhdGEuZ2V0KCJk
  >> "!B64TMP!" echo YXRhIikgaWYgaXNpbnN0YW5jZShkYXRhLmdldCgiZGF0YSIpLCBkaWN0KSBlbHNlIGRhdGEKICAg
  >> "!B64TMP!" echo IHByaW50ZWQgPSAwCiAgICBmb3IgZm10IGluIGZvcm1hdHM6CiAgICAgICAgdmFsdWUgPSBwYXls
  >> "!B64TMP!" echo b2FkLmdldChmbXQpCiAgICAgICAgaWYgdmFsdWUgaXMgTm9uZToKICAgICAgICAgICAgY29udGlu
  >> "!B64TMP!" echo dWUKICAgICAgICBpZiBwcmludGVkOgogICAgICAgICAgICBwcmludCgpCiAgICAgICAgcHJpbnRf
  >> "!B64TMP!" echo ZmllbGQoZm10LCB2YWx1ZSwgbWF4X2NoYXJzKQogICAgICAgIHByaW50ZWQgKz0gMQogICAgaWYg
  >> "!B64TMP!" echo bm90IHByaW50ZWQ6CiAgICAgICAgcHJpbnQoZiJQQVJTRSBSRVRVUk5FRCBOTyBDT05URU5UIGZv
  >> "!B64TMP!" echo ciB7ZmlsZV9wYXRofSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludChqc29uLmR1bXBz
  >> "!B64TMP!" echo KGRhdGEpWzo4MDBdLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDEKICAgIHJldHVy
  >> "!B64TMP!" echo biAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_parse.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_create.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_create.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_create.py" "!TARGET!\local-web-search\scripts\web_monitor_create.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_create.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_create.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS635240605.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJDcmVhdGUgYSByZWN1cnJpbmcgRmlyZWNyYXdsIG1v
  >> "!B64TMP!" echo bml0b3Ig4oCUIGEgc2NyYXBlLCBjcmF3bCwgb3Igc2VhcmNoIGNoZWNrCnRoYXQgY29tcGFyZXMg
  >> "!B64TMP!" echo ZWFjaCBydW4gd2l0aCBpdHMgcmV0YWluZWQgcHJlZGVjZXNzb3IgKHRoZQpmaXJlY3Jhd2xfbW9u
  >> "!B64TMP!" echo aXRvcl9jcmVhdGUgTUNQIHRvb2wpLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX21vbml0b3JfY3Jl
  >> "!B64TMP!" echo YXRlLnB5ICgtLWJvZHkgJ3suLi59JyB8IC0tYm9keS1maWxlIG1vbml0b3IuanNvbikKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgWy0tanNvbl0KClNlbGYtaGVhbGluZzogaWYgdGhl
  >> "!B64TMP!" echo IGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0aGUK
  >> "!B64TMP!" echo Y29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRzIHRo
  >> "!B64TMP!" echo ZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCByZXRy
  >> "!B64TMP!" echo aWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVzCnNlbGYtaGVhbCBvbmNlOyB0cmFu
  >> "!B64TMP!" echo c2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdpdGggYSBzaG9ydCBiYWNrb2ZmLgpZ
  >> "!B64TMP!" echo b3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5weSBmaXJzdCDigJQganVzdCBydW4g
  >> "!B64TMP!" echo dGhlIHNjcmlwdC4KCmAtLWJvZHlgIGlzIHRoZSBmdWxsIG1vbml0b3IgY29uZmlndXJhdGlvbiBh
  >> "!B64TMP!" echo cyBKU09OIChzYW1lIG9iamVjdCB0aGUgTUNQCnRvb2wncyBgYm9keWAgcGFyYW1ldGVyIHRha2Vz
  >> "!B64TMP!" echo OiBuYW1lLCBzY2hlZHVsZSwgZ29hbCwgdGFyZ2V0cywgd2ViaG9vaywKbm90aWZpY2F0aW9uLCBy
  >> "!B64TMP!" echo ZXRlbnRpb24sIC4uLikuIGAtLWJvZHktZmlsZWAgcmVhZHMgaXQgZnJvbSBhIGZpbGUgaW5zdGVh
  >> "!B64TMP!" echo ZC4KUHJpbnRzIHRoZSBjcmVhdGVkIG1vbml0b3IgYXMgcHJldHR5IEpTT047IGAtLWpzb25gIHBy
  >> "!B64TMP!" echo aW50cyB0aGUgcmF3IEFQSQpyZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEg
  >> "!B64TMP!" echo RmlyZWNyYXdsIEFDQ09VTlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApG
  >> "!B64TMP!" echo SVJFQ1JBV0xfQVBJX0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVj
  >> "!B64TMP!" echo cmF3bC5kZXYgZm9yIHRoZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5v
  >> "!B64TMP!" echo dCBleHBvc2UgdGhlbS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMu
  >> "!B64TMP!" echo cGF0aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykp
  >> "!B64TMP!" echo KQppbXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBj
  >> "!B64TMP!" echo bGllbnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVm
  >> "!B64TMP!" echo IHJlYWRfYm9keV9hcmcoYXJncyk6CiAgICAiIiJSZXR1cm4gdGhlIG1vbml0b3IgYm9keSBhcyBh
  >> "!B64TMP!" echo IGRpY3QgZnJvbSAtLWJvZHkgLyAtLWJvZHktZmlsZSwgb3IKICAgIChOb25lLCBlcnJvci1tZXNz
  >> "!B64TMP!" echo YWdlKS4iIiIKICAgIGJvZHlfcmF3LCBib2R5X2ZpbGUgPSBOb25lLCBOb25lCiAgICBpID0gMAog
  >> "!B64TMP!" echo ICAgd2hpbGUgaSA8IGxlbihhcmdzKToKICAgICAgICBhID0gYXJnc1tpXQogICAgICAgIGlmIGEg
  >> "!B64TMP!" echo PT0gIi0tYm9keSIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBpICs9IDEKICAg
  >> "!B64TMP!" echo ICAgICAgICAgYm9keV9yYXcgPSBhcmdzW2ldCiAgICAgICAgZWxpZiBhID09ICItLWJvZHktZmls
  >> "!B64TMP!" echo ZSIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAg
  >> "!B64TMP!" echo Ym9keV9maWxlID0gYXJnc1tpXQogICAgICAgIGkgKz0gMQogICAgaWYgYm9keV9yYXcgaXMgbm90
  >> "!B64TMP!" echo IE5vbmUgYW5kIGJvZHlfZmlsZSBpcyBub3QgTm9uZToKICAgICAgICByZXR1cm4gTm9uZSwgInBy
  >> "!B64TMP!" echo b3ZpZGUgZWl0aGVyIC0tYm9keSBvciAtLWJvZHktZmlsZSwgbm90IGJvdGgiCiAgICBpZiBib2R5
  >> "!B64TMP!" echo X2ZpbGUgaXMgbm90IE5vbmU6CiAgICAgICAgdHJ5OgogICAgICAgICAgICB3aXRoIG9wZW4oYm9k
  >> "!B64TMP!" echo eV9maWxlLCBlbmNvZGluZz0idXRmLTgiKSBhcyBmaDoKICAgICAgICAgICAgICAgIGJvZHlfcmF3
  >> "!B64TMP!" echo ID0gZmgucmVhZCgpCiAgICAgICAgZXhjZXB0IE9TRXJyb3IgYXMgZToKICAgICAgICAgICAgcmV0
  >> "!B64TMP!" echo dXJuIE5vbmUsICJjb3VsZCBub3QgcmVhZCB7fToge30iLmZvcm1hdChib2R5X2ZpbGUsIGUpCiAg
  >> "!B64TMP!" echo ICBpZiBib2R5X3JhdyBpcyBOb25lOgogICAgICAgIHJldHVybiBOb25lLCAoImEgbW9uaXRvciBi
  >> "!B64TMP!" echo b2R5IGlzIHJlcXVpcmVkOiAtLWJvZHkgJ3suLi59JyAiCiAgICAgICAgICAgICAgICAgICAgICAi
  >> "!B64TMP!" echo KGZ1bGwgbW9uaXRvciBKU09OKSBvciAtLWJvZHktZmlsZSBGSUxFIikKICAgIHRyeToKICAgICAg
  >> "!B64TMP!" echo ICBib2R5ID0ganNvbi5sb2Fkcyhib2R5X3JhdykKICAgIGV4Y2VwdCBWYWx1ZUVycm9yIGFzIGU6
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIE5vbmUsICJ0aGUgYm9keSBpcyBub3QgdmFsaWQgSlNPTjoge30iLmZv
  >> "!B64TMP!" echo cm1hdChlKQogICAgaWYgbm90IGlzaW5zdGFuY2UoYm9keSwgZGljdCk6CiAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IE5vbmUsICJ0aGUgbW9uaXRvciBib2R5IG11c3QgYmUgYSBKU09OIG9iamVjdCIKICAgIHJldHVy
  >> "!B64TMP!" echo biBib2R5LCBOb25lCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpd
  >> "!B64TMP!" echo CiAgICBhc19qc29uID0gIi0tanNvbiIgaW4gYXJncwogICAgYm9keSwgZXJyID0gcmVhZF9ib2R5
  >> "!B64TMP!" echo X2FyZyhhcmdzKQogICAgaWYgZXJyOgogICAgICAgIHByaW50KCJ1c2FnZTogd2ViX21vbml0b3Jf
  >> "!B64TMP!" echo Y3JlYXRlLnB5ICgtLWJvZHkgJ3suLi59JyB8ICIKICAgICAgICAgICAgICAiLS1ib2R5LWZpbGUg
  >> "!B64TMP!" echo bW9uaXRvci5qc29uKSBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBwcmludChl
  >> "!B64TMP!" echo cnIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgoKICAgIHRyeToKICAgICAgICBk
  >> "!B64TMP!" echo YXRhID0gZmMuY2FsbCgiL3YxL21vbml0b3IiLCBtZXRob2Q9IlBPU1QiLCBib2R5PWJvZHkpCiAg
  >> "!B64TMP!" echo ICBleGNlcHQgZmMuRmNFcnJvciBhcyBlOgogICAgICAgIHByaW50KGYiTU9OSVRPUiBDUkVBVEUg
  >> "!B64TMP!" echo RkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAg
  >> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAg
  >> "!B64TMP!" echo IGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gMAogICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhLCBpbmRlbnQ9MikpCiAgICByZXR1cm4gMAoK
  >> "!B64TMP!" echo CmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_create.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_list.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_list.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_list.py" "!TARGET!\local-web-search\scripts\web_monitor_list.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_list.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_list.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS3195686845.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJMaXN0IHRoZSBGaXJlY3Jhd2wgbW9uaXRvcnMgb2Yg
  >> "!B64TMP!" echo dGhlIGF1dGhlbnRpY2F0ZWQgYWNjb3VudCAodGhlCmZpcmVjcmF3bF9tb25pdG9yX2xpc3QgTUNQ
  >> "!B64TMP!" echo IHRvb2wpLCB3aXRoIG9wdGlvbmFsIHBhZ2luYXRpb24uCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
  >> "!B64TMP!" echo bW9uaXRvcl9saXN0LnB5IFstLWxpbWl0IE5dIFstLW9mZnNldCBOXSBbLS1qc29uXQoKU2VsZi1o
  >> "!B64TMP!" echo ZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIg
  >> "!B64TMP!" echo ZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGlj
  >> "!B64TMP!" echo YWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVu
  >> "!B64TMP!" echo LmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1o
  >> "!B64TMP!" echo ZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNo
  >> "!B64TMP!" echo b3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0
  >> "!B64TMP!" echo IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIG9uZSBsaW5lIHBlciBtb25pdG9yOiBg
  >> "!B64TMP!" echo Ti4gPGlkPiDigJQgPG5hbWU+ICg8c3RhdGU+KWAuIGAtLWpzb25gIHByaW50cwp0aGUgcmF3IEFQ
  >> "!B64TMP!" echo SSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFDQ09V
  >> "!B64TMP!" echo TlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJX0tF
  >> "!B64TMP!" echo WSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yIHRo
  >> "!B64TMP!" echo ZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4K
  >> "!B64TMP!" echo IiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwg
  >> "!B64TMP!" echo b3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNy
  >> "!B64TMP!" echo YXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhl
  >> "!B64TMP!" echo YWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVmIG1haW4oKSAtPiBpbnQ6
  >> "!B64TMP!" echo CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBsaW1pdCwgb2Zmc2V0LCBhc19qc29uID0gTm9u
  >> "!B64TMP!" echo ZSwgTm9uZSwgRmFsc2UKICAgIGkgPSAwCiAgICB3aGlsZSBpIDwgbGVuKGFyZ3MpOgogICAgICAg
  >> "!B64TMP!" echo IGEgPSBhcmdzW2ldCiAgICAgICAgaWYgYSA9PSAiLS1saW1pdCIgYW5kIGkgKyAxIDwgbGVuKGFy
  >> "!B64TMP!" echo Z3MpOgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo bGltaXQgPSBpbnQoYXJnc1tpXSkKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBwcmludChmImludmFsaWQgLS1saW1pdDoge2FyZ3NbaV19IiwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tb2Zm
  >> "!B64TMP!" echo c2V0IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAg
  >> "!B64TMP!" echo ICB0cnk6CiAgICAgICAgICAgICAgICBvZmZzZXQgPSBpbnQoYXJnc1tpXSkKICAgICAgICAgICAg
  >> "!B64TMP!" echo ZXhjZXB0IFZhbHVlRXJyb3I6CiAgICAgICAgICAgICAgICBwcmludChmImludmFsaWQgLS1vZmZz
  >> "!B64TMP!" echo ZXQ6IHthcmdzW2ldfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgICAgIHJldHVybiAy
  >> "!B64TMP!" echo CiAgICAgICAgZWxpZiBhID09ICItLWpzb24iOgogICAgICAgICAgICBhc19qc29uID0gVHJ1ZQog
  >> "!B64TMP!" echo ICAgICAgIGVsaWYgYS5zdGFydHN3aXRoKCItLSIpOgogICAgICAgICAgICBwcmludChmInVua25v
  >> "!B64TMP!" echo d24gb3B0aW9uOiB7YX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAyCiAg
  >> "!B64TMP!" echo ICAgICAgZWxzZToKICAgICAgICAgICAgcHJpbnQoZiJ1bmV4cGVjdGVkIGFyZ3VtZW50OiB7YX0i
  >> "!B64TMP!" echo LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgaSArPSAxCgog
  >> "!B64TMP!" echo ICAgcXVlcnkgPSB7fQogICAgaWYgbGltaXQgaXMgbm90IE5vbmU6CiAgICAgICAgcXVlcnlbImxp
  >> "!B64TMP!" echo bWl0Il0gPSBsaW1pdAogICAgaWYgb2Zmc2V0IGlzIG5vdCBOb25lOgogICAgICAgIHF1ZXJ5WyJv
  >> "!B64TMP!" echo ZmZzZXQiXSA9IG9mZnNldAoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL21v
  >> "!B64TMP!" echo bml0b3IiLCBtZXRob2Q9IkdFVCIsIHF1ZXJ5PXF1ZXJ5KQogICAgZXhjZXB0IGZjLkZjRXJyb3Ig
  >> "!B64TMP!" echo YXMgZToKICAgICAgICBwcmludChmIk1PTklUT1IgTElTVCBGQUlMRUQ6IHtlfSIsIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmls
  >> "!B64TMP!" echo ZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBw
  >> "!B64TMP!" echo cmludChqc29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCgogICAgbW9uaXRvcnMgPSBk
  >> "!B64TMP!" echo YXRhLmdldCgibW9uaXRvcnMiKQogICAgaWYgbm90IGlzaW5zdGFuY2UobW9uaXRvcnMsIGxpc3Qp
  >> "!B64TMP!" echo OgogICAgICAgIG1vbml0b3JzID0gZGF0YS5nZXQoImRhdGEiKQogICAgaWYgbm90IGlzaW5zdGFu
  >> "!B64TMP!" echo Y2UobW9uaXRvcnMsIGxpc3QpOgogICAgICAgIG1vbml0b3JzID0gZGF0YSBpZiBpc2luc3RhbmNl
  >> "!B64TMP!" echo KGRhdGEsIGxpc3QpIGVsc2UgW10KICAgIGlmIG5vdCBtb25pdG9yczoKICAgICAgICBwcmludCgi
  >> "!B64TMP!" echo KG5vIG1vbml0b3JzKSIpCiAgICAgICAgcmV0dXJuIDAKICAgIGZvciBuLCBtb25pdG9yIGluIGVu
  >> "!B64TMP!" echo dW1lcmF0ZShtb25pdG9ycywgMSk6CiAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UobW9uaXRvciwg
  >> "!B64TMP!" echo ZGljdCk6CiAgICAgICAgICAgIHByaW50KGYie259LiB7bW9uaXRvcn0iKQogICAgICAgICAgICBj
  >> "!B64TMP!" echo b250aW51ZQogICAgICAgIG1pZCA9IG1vbml0b3IuZ2V0KCJpZCIpIG9yIG1vbml0b3IuZ2V0KCJt
  >> "!B64TMP!" echo b25pdG9ySWQiKSBvciAiPyIKICAgICAgICBuYW1lID0gbW9uaXRvci5nZXQoIm5hbWUiKSBvciAi
  >> "!B64TMP!" echo KHVubmFtZWQpIgogICAgICAgIHN0YXRlID0gKG1vbml0b3IuZ2V0KCJzdGF0ZSIpIG9yIG1vbml0
  >> "!B64TMP!" echo b3IuZ2V0KCJzdGF0dXMiKQogICAgICAgICAgICAgICAgIG9yICgiYWN0aXZlIiBpZiBtb25pdG9y
  >> "!B64TMP!" echo LmdldCgiYWN0aXZlIikgZWxzZSAicGF1c2VkIikpCiAgICAgICAgcHJpbnQoZiJ7bn0uIHttaWR9
  >> "!B64TMP!" echo IOKAlCB7bmFtZX0gKHtzdGF0ZX0pIikKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9f
  >> "!B64TMP!" echo bWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_list.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_get.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_get.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_get.py" "!TARGET!\local-web-search\scripts\web_monitor_get.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_get.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_get.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1880791886.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZXRyaWV2ZSBvbmUgRmlyZWNyYXdsIG1vbml0b3Ig
  >> "!B64TMP!" echo YnkgSUQsIGluY2x1ZGluZyBpdHMgY29uZmlndXJhdGlvbiBhbmQKY3VycmVudCBzdGF0ZSAodGhl
  >> "!B64TMP!" echo IGZpcmVjcmF3bF9tb25pdG9yX2dldCBNQ1AgdG9vbCkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJf
  >> "!B64TMP!" echo bW9uaXRvcl9nZXQucHkgPGlkPiBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwt
  >> "!B64TMP!" echo c2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWlu
  >> "!B64TMP!" echo ZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhl
  >> "!B64TMP!" echo IHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhl
  >> "!B64TMP!" echo IHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0
  >> "!B64TMP!" echo MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBO
  >> "!B64TMP!" echo T1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2Ny
  >> "!B64TMP!" echo aXB0LgoKUHJpbnRzIHRoZSBtb25pdG9yIGFzIHByZXR0eSBKU09OLiBgLS1qc29uYCBwcmludHMg
  >> "!B64TMP!" echo dGhlIHJhdyBBUEkgcmVzcG9uc2UKaW5zdGVhZC4gVGhpcyBkb2VzIG5vdCBydW4gb3IgbW9kaWZ5
  >> "!B64TMP!" echo IHRoZSBtb25pdG9yLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFDQ09VTlQgZmVh
  >> "!B64TMP!" echo dHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJX0tFWSwgYW5k
  >> "!B64TMP!" echo IEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yIHRoZQpjbG91
  >> "!B64TMP!" echo ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4KIiIiCmlt
  >> "!B64TMP!" echo cG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3MucGF0
  >> "!B64TMP!" echo aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXdsX2Fw
  >> "!B64TMP!" echo aSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwKCkVO
  >> "!B64TMP!" echo RFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBh
  >> "!B64TMP!" echo cmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBpZiBub3QgYXJncyBvciBhcmdzWzBdLnN0YXJ0c3dpdGgo
  >> "!B64TMP!" echo Ii0tIik6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3ZWJfbW9uaXRvcl9nZXQucHkgPGlkPiBbLS1q
  >> "!B64TMP!" echo c29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgogICAgbW9uaXRvcl9pZCA9
  >> "!B64TMP!" echo IGFyZ3NbMF0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBhcmdzWzE6XQoKICAgIHRyeToKICAg
  >> "!B64TMP!" echo ICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL21vbml0b3IvIiArIHN0cihtb25pdG9yX2lkKSwgbWV0
  >> "!B64TMP!" echo aG9kPSJHRVQiKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIk1P
  >> "!B64TMP!" echo TklUT1IgR0VUIEZBSUxFRCBmb3Ige21vbml0b3JfaWR9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIp
  >> "!B64TMP!" echo CiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0
  >> "!B64TMP!" echo ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNv
  >> "!B64TMP!" echo bi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQoanNvbi5kdW1wcyhkYXRh
  >> "!B64TMP!" echo LCBpbmRlbnQ9MikpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAg
  >> "!B64TMP!" echo ICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_get.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_update.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_update.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_update.py" "!TARGET!\local-web-search\scripts\web_monitor_update.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_update.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_update.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS508901295.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJQYXRjaCBhbiBleGlzdGluZyBGaXJlY3Jhd2wgbW9u
  >> "!B64TMP!" echo aXRvciBieSBJRCAodGhlIGZpcmVjcmF3bF9tb25pdG9yX3VwZGF0ZQpNQ1AgdG9vbCk6IGNoYW5n
  >> "!B64TMP!" echo ZSBpdHMgbmFtZSwgYWN0aXZlL3BhdXNlZCBzdGF0dXMsIHNjaGVkdWxlLCB0YXJnZXRzLCBnb2Fs
  >> "!B64TMP!" echo LApqdWRnaW5nLCB3ZWJob29rLCBub3RpZmljYXRpb25zLCBvciByZXRlbnRpb24g4oCUIHRoZXNl
  >> "!B64TMP!" echo IGNoYW5nZXMgYWZmZWN0IGZ1dHVyZQpzY2hlZHVsZWQgY2hlY2tzLgoKVXNhZ2U6CiAgICBweXRo
  >> "!B64TMP!" echo b24gd2ViX21vbml0b3JfdXBkYXRlLnB5IDxpZD4gKC0tYm9keSAney4uLn0nIHwgLS1ib2R5LWZp
  >> "!B64TMP!" echo bGUgcGF0Y2guanNvbikKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFstLWpzb25d
  >> "!B64TMP!" echo CgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUg
  >> "!B64TMP!" echo KERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBh
  >> "!B64TMP!" echo dXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2su
  >> "!B64TMP!" echo cHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJl
  >> "!B64TMP!" echo cwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3
  >> "!B64TMP!" echo aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2su
  >> "!B64TMP!" echo cHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpgLS1ib2R5YCBpcyB0aGUgcGF0Y2gg
  >> "!B64TMP!" echo YXMgSlNPTiAoc2FtZSBvYmplY3QgdGhlIE1DUCB0b29sJ3MgYGJvZHlgIHBhcmFtZXRlcgp0YWtl
  >> "!B64TMP!" echo cyk7IGAtLWJvZHktZmlsZWAgcmVhZHMgaXQgZnJvbSBhIGZpbGUgaW5zdGVhZC4gUHJpbnRzIHRo
  >> "!B64TMP!" echo ZSB1cGRhdGVkCm1vbml0b3IgYXMgcHJldHR5IEpTT047IGAtLWpzb25gIHByaW50cyB0aGUgcmF3
  >> "!B64TMP!" echo IEFQSSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFD
  >> "!B64TMP!" echo Q09VTlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJ
  >> "!B64TMP!" echo X0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9y
  >> "!B64TMP!" echo IHRoZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhl
  >> "!B64TMP!" echo bS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQo
  >> "!B64TMP!" echo MCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmly
  >> "!B64TMP!" echo ZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxm
  >> "!B64TMP!" echo LWhlYWwKaW1wb3J0IHdlYl9tb25pdG9yX2NyZWF0ZSAgIyBzaWJsaW5nOiBzaGFyZWQgLS1ib2R5
  >> "!B64TMP!" echo IC8gLS1ib2R5LWZpbGUgcmVhZGluZwoKRU5EUE9JTlQgPSBmYy51cmwoIi92MS9tb25pdG9yIikK
  >> "!B64TMP!" echo CgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBh
  >> "!B64TMP!" echo cmdzIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdl
  >> "!B64TMP!" echo Yl9tb25pdG9yX3VwZGF0ZS5weSA8aWQ+ICgtLWJvZHkgJ3suLi59JyB8ICIKICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAiLS1ib2R5LWZpbGUgcGF0Y2guanNvbikgWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAg
  >> "!B64TMP!" echo ICAgICAgcmV0dXJuIDIKICAgIG1vbml0b3JfaWQgPSBhcmdzWzBdCiAgICBhc19qc29uID0gIi0t
  >> "!B64TMP!" echo anNvbiIgaW4gYXJncwogICAgYm9keSwgZXJyID0gd2ViX21vbml0b3JfY3JlYXRlLnJlYWRfYm9k
  >> "!B64TMP!" echo eV9hcmcoYXJncykKICAgIGlmIGVycjoKICAgICAgICBwcmludChlcnIsIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgICAgICByZXR1cm4gMgoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3Yx
  >> "!B64TMP!" echo L21vbml0b3IvIiArIHN0cihtb25pdG9yX2lkKSwgbWV0aG9kPSJQQVRDSCIsCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgYm9keT1ib2R5KQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAg
  >> "!B64TMP!" echo ICBwcmludChmIk1PTklUT1IgVVBEQVRFIEZBSUxFRCBmb3Ige21vbml0b3JfaWR9OiB7ZX0iLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhp
  >> "!B64TMP!" echo bnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAg
  >> "!B64TMP!" echo ICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAgcHJpbnQo
  >> "!B64TMP!" echo anNvbi5kdW1wcyhkYXRhLCBpbmRlbnQ9MikpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09
  >> "!B64TMP!" echo ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_update.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_delete.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_delete.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_delete.py" "!TARGET!\local-web-search\scripts\web_monitor_delete.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_delete.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_delete.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS969626275.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJQZXJtYW5lbnRseSBkZWxldGUgYSBGaXJlY3Jhd2wg
  >> "!B64TMP!" echo bW9uaXRvciBieSBJRCBhbmQgc3RvcCBpdHMgZnV0dXJlIHNjaGVkdWxlCih0aGUgZmlyZWNyYXds
  >> "!B64TMP!" echo X21vbml0b3JfZGVsZXRlIE1DUCB0b29sKS4gVGhpcyBjYW5ub3QgYmUgdW5kb25lLgoKVXNhZ2U6
  >> "!B64TMP!" echo CiAgICBweXRob24gd2ViX21vbml0b3JfZGVsZXRlLnB5IDxpZD4gWy0tanNvbl0KClNlbGYtaGVh
  >> "!B64TMP!" echo bGluZzogaWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJlYWNoYWJsZSAoRG9ja2VyIGVu
  >> "!B64TMP!" echo Z2luZSBvciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMgc2NyaXB0IGF1dG9tYXRpY2Fs
  >> "!B64TMP!" echo bHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3VyZV9zdGFjay5weSAvIFJ1bi5i
  >> "!B64TMP!" echo YXQpIGFuZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9uIGZhaWx1cmVzCnNlbGYtaGVh
  >> "!B64TMP!" echo bCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSByZXRyaWVkIHdpdGggYSBzaG9y
  >> "!B64TMP!" echo dCBiYWNrb2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3VyZV9zdGFjay5weSBmaXJzdCDi
  >> "!B64TMP!" echo gJQganVzdCBydW4gdGhlIHNjcmlwdC4KClByaW50cyBhIGNvbmZpcm1hdGlvbiAocGx1cyB0aGUg
  >> "!B64TMP!" echo QVBJJ3MgcmVzcG9uc2UgYm9keSB3aGVuIG9uZSBpcyByZXR1cm5lZCkuCmAtLWpzb25gIHByaW50
  >> "!B64TMP!" echo cyB0aGUgcmF3IEFQSSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmly
  >> "!B64TMP!" echo ZWNyYXdsIEFDQ09VTlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJF
  >> "!B64TMP!" echo Q1JBV0xfQVBJX0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3
  >> "!B64TMP!" echo bC5kZXYgZm9yIHRoZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBl
  >> "!B64TMP!" echo eHBvc2UgdGhlbS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0
  >> "!B64TMP!" echo aC5pbnNlcnQoMCwgb3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQpp
  >> "!B64TMP!" echo bXBvcnQgZmlyZWNyYXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGll
  >> "!B64TMP!" echo bnQgKyBzZWxmLWhlYWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgoKZGVmIG1h
  >> "!B64TMP!" echo aW4oKSAtPiBpbnQ6CiAgICBhcmdzID0gc3lzLmFyZ3ZbMTpdCiAgICBpZiBub3QgYXJncyBvciBh
  >> "!B64TMP!" echo cmdzWzBdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3ZWJfbW9uaXRv
  >> "!B64TMP!" echo cl9kZWxldGUucHkgPGlkPiBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gMgogICAgbW9uaXRvcl9pZCA9IGFyZ3NbMF0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBh
  >> "!B64TMP!" echo cmdzWzE6XQoKICAgIHRyeToKICAgICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL21vbml0b3IvIiAr
  >> "!B64TMP!" echo IHN0cihtb25pdG9yX2lkKSwgbWV0aG9kPSJERUxFVEUiKQogICAgZXhjZXB0IGZjLkZjRXJyb3Ig
  >> "!B64TMP!" echo YXMgZToKICAgICAgICBwcmludChmIk1PTklUT1IgREVMRVRFIEZBSUxFRCBmb3Ige21vbml0b3Jf
  >> "!B64TMP!" echo aWR9OiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAg
  >> "!B64TMP!" echo ICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlm
  >> "!B64TMP!" echo IGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo MAogICAgcHJpbnQoZiJNb25pdG9yIHttb25pdG9yX2lkfSBkZWxldGVkLiIpCiAgICBpZiBkYXRh
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KGpzb24uZHVtcHMoZGF0YSwgaW5kZW50PTIpKQogICAgcmV0dXJuIDAK
  >> "!B64TMP!" echo CgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_delete.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_run.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_run.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_run.py" "!TARGET!\local-web-search\scripts\web_monitor_run.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_run.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_run.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2084907039.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJRdWV1ZSBhbiBpbW1lZGlhdGUgY2hlY2sgZm9yIGEg
  >> "!B64TMP!" echo RmlyZWNyYXdsIG1vbml0b3IsIG91dHNpZGUgaXRzIG5vcm1hbApzY2hlZHVsZSAodGhlIGZpcmVj
  >> "!B64TMP!" echo cmF3bF9tb25pdG9yX3J1biBNQ1AgdG9vbCkuCgpVc2FnZToKICAgIHB5dGhvbiB3ZWJfbW9uaXRv
  >> "!B64TMP!" echo cl9ydW4ucHkgPGlkPiBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNo
  >> "!B64TMP!" echo IHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFy
  >> "!B64TMP!" echo ZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUg
  >> "!B64TMP!" echo bG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVl
  >> "!B64TMP!" echo c3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4
  >> "!B64TMP!" echo IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVl
  >> "!B64TMP!" echo ZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoK
  >> "!B64TMP!" echo UHJpbnRzIHRoZSBxdWV1ZWQgY2hlY2sgYXMgcHJldHR5IEpTT04uIGAtLWpzb25gIHByaW50cyB0
  >> "!B64TMP!" echo aGUgcmF3IEFQSSByZXNwb25zZQppbnN0ZWFkLiBGb2xsb3cgdGhlIGNoZWNrIHdpdGggd2ViX21v
  >> "!B64TMP!" echo bml0b3JfY2hlY2tzLnB5IC8gd2ViX21vbml0b3JfY2hlY2sucHkuCgpOT1RFOiBtb25pdG9ycyBh
  >> "!B64TMP!" echo cmUgYSBGaXJlY3Jhd2wgQUNDT1VOVCBmZWF0dXJlIOKAlCB0aGV5IG5lZWQgYW4gQVBJIGtleSAo
  >> "!B64TMP!" echo c2V0CkZJUkVDUkFXTF9BUElfS0VZLCBhbmQgRklSRUNSQVdMX0FQSV9VUkw9aHR0cHM6Ly9hcGku
  >> "!B64TMP!" echo ZmlyZWNyYXdsLmRldiBmb3IgdGhlCmNsb3VkIEFQSSk7IHRoZSBzZWxmLWhvc3RlZCBzdGFjayBt
  >> "!B64TMP!" echo YXkgbm90IGV4cG9zZSB0aGVtLgoiIiIKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCBzeXMK
  >> "!B64TMP!" echo CnN5cy5wYXRoLmluc2VydCgwLCBvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmls
  >> "!B64TMP!" echo ZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xfYXBpIGFzIGZjICAjIHNpYmxpbmc6IEZpcmVjcmF3bCBI
  >> "!B64TMP!" echo VFRQIGNsaWVudCArIHNlbGYtaGVhbAoKRU5EUE9JTlQgPSBmYy51cmwoIi92MS9tb25pdG9yIikK
  >> "!B64TMP!" echo CgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBh
  >> "!B64TMP!" echo cmdzIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdl
  >> "!B64TMP!" echo Yl9tb25pdG9yX3J1bi5weSA8aWQ+IFstLWpzb25dIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAg
  >> "!B64TMP!" echo IHJldHVybiAyCiAgICBtb25pdG9yX2lkID0gYXJnc1swXQogICAgYXNfanNvbiA9ICItLWpzb24i
  >> "!B64TMP!" echo IGluIGFyZ3NbMTpdCgogICAgdHJ5OgogICAgICAgIGRhdGEgPSBmYy5jYWxsKCIvdjEvbW9uaXRv
  >> "!B64TMP!" echo ci8iICsgc3RyKG1vbml0b3JfaWQpICsgIi9ydW4iLAogICAgICAgICAgICAgICAgICAgICAgIG1l
  >> "!B64TMP!" echo dGhvZD0iUE9TVCIpCiAgICBleGNlcHQgZmMuRmNFcnJvciBhcyBlOgogICAgICAgIHByaW50KGYi
  >> "!B64TMP!" echo TU9OSVRPUiBSVU4gRkFJTEVEIGZvciB7bW9uaXRvcl9pZH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVy
  >> "!B64TMP!" echo cikKICAgICAgICBpZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMu
  >> "!B64TMP!" echo c3RkZXJyKQogICAgICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChq
  >> "!B64TMP!" echo c29uLmR1bXBzKGRhdGEpKQogICAgICAgIHJldHVybiAwCiAgICBwcmludChqc29uLmR1bXBzKGRh
  >> "!B64TMP!" echo dGEsIGluZGVudD0yKSkKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoK
  >> "!B64TMP!" echo ICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_run.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_checks.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_checks.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_checks.py" "!TARGET!\local-web-search\scripts\web_monitor_checks.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_checks.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_checks.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS313295973.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJMaXN0IHRoZSBoaXN0b3JpY2FsIGNoZWNrcyBvZiBh
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBtb25pdG9yICh0aGUKZmlyZWNyYXdsX21vbml0b3JfY2hlY2tzIE1DUCB0b29s
  >> "!B64TMP!" echo KSwgb3B0aW9uYWxseSBmaWx0ZXJlZCBieSBzdGF0dXMgYW5kCnBhZ2luYXRlZC4KClVzYWdlOgog
  >> "!B64TMP!" echo ICAgcHl0aG9uIHdlYl9tb25pdG9yX2NoZWNrcy5weSA8aWQ+IFstLXN0YXR1cyBxdWV1ZWR8cnVu
  >> "!B64TMP!" echo bmluZ3xjb21wbGV0ZWR8ZmFpbGVkfHBhcnRpYWxdCiAgICAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgIFstLWxpbWl0IE5dIFstLW9mZnNldCBOXSBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBp
  >> "!B64TMP!" echo ZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9y
  >> "!B64TMP!" echo IHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFy
  >> "!B64TMP!" echo dHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5k
  >> "!B64TMP!" echo IHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7
  >> "!B64TMP!" echo IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tv
  >> "!B64TMP!" echo ZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0
  >> "!B64TMP!" echo IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIG9uZSBsaW5lIHBlciBjaGVjazogYE4uIDxjaGVja0lk
  >> "!B64TMP!" echo PiA8c3RhdHVzPiA8Y3JlYXRlZEF0PmAuIGAtLWpzb25gCnByaW50cyB0aGUgcmF3IEFQSSByZXNw
  >> "!B64TMP!" echo b25zZSBpbnN0ZWFkLiBSZWFkIG9uZSBjaGVjaydzIHBhZ2UtbGV2ZWwgcmVzdWx0cwp3aXRoIHdl
  >> "!B64TMP!" echo Yl9tb25pdG9yX2NoZWNrLnB5LgoKTk9URTogbW9uaXRvcnMgYXJlIGEgRmlyZWNyYXdsIEFDQ09V
  >> "!B64TMP!" echo TlQgZmVhdHVyZSDigJQgdGhleSBuZWVkIGFuIEFQSSBrZXkgKHNldApGSVJFQ1JBV0xfQVBJX0tF
  >> "!B64TMP!" echo WSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yIHRo
  >> "!B64TMP!" echo ZQpjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4K
  >> "!B64TMP!" echo IiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwg
  >> "!B64TMP!" echo b3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNy
  >> "!B64TMP!" echo YXdsX2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhl
  >> "!B64TMP!" echo YWwKCkVORFBPSU5UID0gZmMudXJsKCIvdjEvbW9uaXRvciIpCgpTVEFUVVNFUyA9ICgicXVldWVk
  >> "!B64TMP!" echo IiwgInJ1bm5pbmciLCAiY29tcGxldGVkIiwgImZhaWxlZCIsICJwYXJ0aWFsIikKCgpkZWYgbWFp
  >> "!B64TMP!" echo bigpIC0+IGludDoKICAgIGFyZ3MgPSBzeXMuYXJndlsxOl0KICAgIGlmIG5vdCBhcmdzIG9yIGFy
  >> "!B64TMP!" echo Z3NbMF0uc3RhcnRzd2l0aCgiLS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdlYl9tb25pdG9y
  >> "!B64TMP!" echo X2NoZWNrcy5weSA8aWQ+ICIKICAgICAgICAgICAgICAiWy0tc3RhdHVzIHF1ZXVlZHxydW5uaW5n
  >> "!B64TMP!" echo fGNvbXBsZXRlZHxmYWlsZWR8cGFydGlhbF0gIgogICAgICAgICAgICAgICJbLS1saW1pdCBOXSBb
  >> "!B64TMP!" echo LS1vZmZzZXQgTl0gWy0tanNvbl0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIK
  >> "!B64TMP!" echo ICAgIG1vbml0b3JfaWQgPSBhcmdzWzBdCiAgICBzdGF0dXMsIGxpbWl0LCBvZmZzZXQsIGFzX2pz
  >> "!B64TMP!" echo b24gPSBOb25lLCBOb25lLCBOb25lLCBGYWxzZQogICAgaSA9IDEKICAgIHdoaWxlIGkgPCBsZW4o
  >> "!B64TMP!" echo YXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAgICBpZiBhID09ICItLXN0YXR1cyIgYW5k
  >> "!B64TMP!" echo IGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBpICs9IDEKICAgICAgICAgICAgc3RhdHVz
  >> "!B64TMP!" echo ID0gYXJnc1tpXQogICAgICAgICAgICBpZiBzdGF0dXMgbm90IGluIFNUQVRVU0VTOgogICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgcHJpbnQoZiJpbnZhbGlkIC0tc3RhdHVzOiB7c3RhdHVzfSAiCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICBmIihvbmUgb2YgeycsICcuam9pbihTVEFUVVNFUyl9KSIsIGZpbGU9c3lzLnN0
  >> "!B64TMP!" echo ZGVycikKICAgICAgICAgICAgICAgIHJldHVybiAyCiAgICAgICAgZWxpZiBhID09ICItLWxpbWl0
  >> "!B64TMP!" echo IiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAgICB0
  >> "!B64TMP!" echo cnk6CiAgICAgICAgICAgICAgICBsaW1pdCA9IGludChhcmdzW2ldKQogICAgICAgICAgICBleGNl
  >> "!B64TMP!" echo cHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgICAgIHByaW50KGYiaW52YWxpZCAtLWxpbWl0OiB7
  >> "!B64TMP!" echo YXJnc1tpXX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgICAgICAgICByZXR1cm4gMgogICAg
  >> "!B64TMP!" echo ICAgIGVsaWYgYSA9PSAiLS1vZmZzZXQiIGFuZCBpICsgMSA8IGxlbihhcmdzKToKICAgICAgICAg
  >> "!B64TMP!" echo ICAgaSArPSAxCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIG9mZnNldCA9IGludChh
  >> "!B64TMP!" echo cmdzW2ldKQogICAgICAgICAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICAgICAgICAgIHBy
  >> "!B64TMP!" echo aW50KGYiaW52YWxpZCAtLW9mZnNldDoge2FyZ3NbaV19IiwgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tanNvbiI6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGFzX2pzb24gPSBUcnVlCiAgICAgICAgZWxpZiBhLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHByaW50KGYidW5rbm93biBvcHRpb246IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbHNlOgogICAgICAgICAgICBwcmludChmInVuZXhw
  >> "!B64TMP!" echo ZWN0ZWQgYXJndW1lbnQ6IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICAgICAgcmV0dXJu
  >> "!B64TMP!" echo IDIKICAgICAgICBpICs9IDEKCiAgICBxdWVyeSA9IHt9CiAgICBpZiBzdGF0dXMgaXMgbm90IE5v
  >> "!B64TMP!" echo bmU6CiAgICAgICAgcXVlcnlbInN0YXR1cyJdID0gc3RhdHVzCiAgICBpZiBsaW1pdCBpcyBub3Qg
  >> "!B64TMP!" echo Tm9uZToKICAgICAgICBxdWVyeVsibGltaXQiXSA9IGxpbWl0CiAgICBpZiBvZmZzZXQgaXMgbm90
  >> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgcXVlcnlbIm9mZnNldCJdID0gb2Zmc2V0CgogICAgdHJ5OgogICAgICAg
  >> "!B64TMP!" echo IGRhdGEgPSBmYy5jYWxsKCIvdjEvbW9uaXRvci8iICsgc3RyKG1vbml0b3JfaWQpICsgIi9jaGVj
  >> "!B64TMP!" echo a3MiLAogICAgICAgICAgICAgICAgICAgICAgIG1ldGhvZD0iR0VUIiwgcXVlcnk9cXVlcnkpCiAg
  >> "!B64TMP!" echo ICBleGNlcHQgZmMuRmNFcnJvciBhcyBlOgogICAgICAgIHByaW50KGYiTU9OSVRPUiBDSEVDS1Mg
  >> "!B64TMP!" echo RkFJTEVEIGZvciB7bW9uaXRvcl9pZH06IHtlfSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBp
  >> "!B64TMP!" echo ZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChqc29uLmR1bXBzKGRh
  >> "!B64TMP!" echo dGEpKQogICAgICAgIHJldHVybiAwCgogICAgY2hlY2tzID0gZGF0YS5nZXQoImNoZWNrcyIpCiAg
  >> "!B64TMP!" echo ICBpZiBub3QgaXNpbnN0YW5jZShjaGVja3MsIGxpc3QpOgogICAgICAgIGNoZWNrcyA9IGRhdGEu
  >> "!B64TMP!" echo Z2V0KCJkYXRhIikKICAgIGlmIG5vdCBpc2luc3RhbmNlKGNoZWNrcywgbGlzdCk6CiAgICAgICAg
  >> "!B64TMP!" echo Y2hlY2tzID0gZGF0YSBpZiBpc2luc3RhbmNlKGRhdGEsIGxpc3QpIGVsc2UgW10KICAgIGlmIG5v
  >> "!B64TMP!" echo dCBjaGVja3M6CiAgICAgICAgcHJpbnQoIihubyBjaGVja3MpIikKICAgICAgICByZXR1cm4gMAog
  >> "!B64TMP!" echo ICAgZm9yIG4sIGNoZWNrIGluIGVudW1lcmF0ZShjaGVja3MsIDEpOgogICAgICAgIGlmIG5vdCBp
  >> "!B64TMP!" echo c2luc3RhbmNlKGNoZWNrLCBkaWN0KToKICAgICAgICAgICAgcHJpbnQoZiJ7bn0uIHtjaGVja30i
  >> "!B64TMP!" echo KQogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGNpZCA9IGNoZWNrLmdldCgiaWQiKSBvciBj
  >> "!B64TMP!" echo aGVjay5nZXQoImNoZWNrSWQiKSBvciAiPyIKICAgICAgICBjc3RhdHVzID0gY2hlY2suZ2V0KCJz
  >> "!B64TMP!" echo dGF0dXMiKSBvciAiPyIKICAgICAgICB3aGVuID0gKGNoZWNrLmdldCgiY3JlYXRlZEF0Iikgb3Ig
  >> "!B64TMP!" echo Y2hlY2suZ2V0KCJzdGFydGVkQXQiKQogICAgICAgICAgICAgICAgb3IgY2hlY2suZ2V0KCJjb21w
  >> "!B64TMP!" echo bGV0ZWRBdCIpIG9yICIiKQogICAgICAgIHByaW50KGYie259LiB7Y2lkfSB7Y3N0YXR1c30ge3do
  >> "!B64TMP!" echo ZW59Ii5yc3RyaXAoKSkKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoK
  >> "!B64TMP!" echo ICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_checks.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_monitor_check.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_monitor_check.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_monitor_check.py" "!TARGET!\local-web-search\scripts\web_monitor_check.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_monitor_check.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_monitor_check.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS763834523.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZXRyaWV2ZSBvbmUgRmlyZWNyYXdsIG1vbml0b3Ig
  >> "!B64TMP!" echo Y2hlY2sgYW5kIGl0cyBwYWdlLWxldmVsIHJlc3VsdHMgKHRoZQpmaXJlY3Jhd2xfbW9uaXRvcl9j
  >> "!B64TMP!" echo aGVjayBNQ1AgdG9vbCkuIFBhZ2VzIHJlcG9ydCBgc2FtZWAsIGBuZXdgLCBgY2hhbmdlZGAsCmBy
  >> "!B64TMP!" echo ZW1vdmVkYCwgb3IgYGVycm9yYDsgZ29hbCBqdWRnaW5nIGFkZHMgYSBtZWFuaW5nZnVsLWNoYW5n
  >> "!B64TMP!" echo ZSBkZWNpc2lvbi4KTWFya2Rvd24gdHJhY2tpbmcgcmV0dXJucyBhIHVuaWZpZWQgdGV4dCBkaWZm
  >> "!B64TMP!" echo OyBKU09OIHRyYWNraW5nIHJldHVybnMgZmllbGQKcGF0aHMgd2l0aCBwcmV2aW91cy9jdXJyZW50
  >> "!B64TMP!" echo IHZhbHVlcy4KClVzYWdlOgogICAgcHl0aG9uIHdlYl9tb25pdG9yX2NoZWNrLnB5IDxpZD4gPGNo
  >> "!B64TMP!" echo ZWNrSWQ+IFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sg
  >> "!B64TMP!" echo aXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMgYXJlIGRvd24p
  >> "!B64TMP!" echo LCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2FtZSBsb2dpYwph
  >> "!B64TMP!" echo cyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVxdWVzdC4gQ29u
  >> "!B64TMP!" echo bmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81eHggYW5zd2Vy
  >> "!B64TMP!" echo cyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1
  >> "!B64TMP!" echo biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQuCgpQcmludHMg
  >> "!B64TMP!" echo dGhlIGNoZWNrIChjb25maWd1cmF0aW9uLCBwYWdlIHJlc3VsdHMsIGRpZmZzKSBhcyBwcmV0dHkg
  >> "!B64TMP!" echo SlNPTi4KYC0tanNvbmAgcHJpbnRzIHRoZSByYXcgQVBJIHJlc3BvbnNlIGluc3RlYWQuCgpOT1RF
  >> "!B64TMP!" echo OiBtb25pdG9ycyBhcmUgYSBGaXJlY3Jhd2wgQUNDT1VOVCBmZWF0dXJlIOKAlCB0aGV5IG5lZWQg
  >> "!B64TMP!" echo YW4gQVBJIGtleSAoc2V0CkZJUkVDUkFXTF9BUElfS0VZLCBhbmQgRklSRUNSQVdMX0FQSV9VUkw9
  >> "!B64TMP!" echo aHR0cHM6Ly9hcGkuZmlyZWNyYXdsLmRldiBmb3IgdGhlCmNsb3VkIEFQSSk7IHRoZSBzZWxmLWhv
  >> "!B64TMP!" echo c3RlZCBzdGFjayBtYXkgbm90IGV4cG9zZSB0aGVtLgoiIiIKaW1wb3J0IGpzb24KaW1wb3J0IG9z
  >> "!B64TMP!" echo CmltcG9ydCBzeXMKCnN5cy5wYXRoLmluc2VydCgwLCBvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5h
  >> "!B64TMP!" echo YnNwYXRoKF9fZmlsZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xfYXBpIGFzIGZjICAjIHNpYmxpbmc6
  >> "!B64TMP!" echo IEZpcmVjcmF3bCBIVFRQIGNsaWVudCArIHNlbGYtaGVhbAoKRU5EUE9JTlQgPSBmYy51cmwoIi92
  >> "!B64TMP!" echo MS9tb25pdG9yIikKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBbYSBmb3IgYSBpbiBz
  >> "!B64TMP!" echo eXMuYXJndlsxOl0gaWYgYSAhPSAiLS1qc29uIl0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBz
  >> "!B64TMP!" echo eXMuYXJndlsxOl0KICAgIGlmIGxlbihhcmdzKSAhPSAyIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgi
  >> "!B64TMP!" echo LS0iKSBvciBhcmdzWzFdLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAgICAgcHJpbnQoInVzYWdlOiB3
  >> "!B64TMP!" echo ZWJfbW9uaXRvcl9jaGVjay5weSA8aWQ+IDxjaGVja0lkPiBbLS1qc29uXSIsCiAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCiAgICBtb25pdG9yX2lkLCBjaGVj
  >> "!B64TMP!" echo a19pZCA9IGFyZ3MKCiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNhbGwoIi92MS9tb25pdG9y
  >> "!B64TMP!" echo LyIgKyBzdHIobW9uaXRvcl9pZCkgKyAiL2NoZWNrcy8iCiAgICAgICAgICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo KyBzdHIoY2hlY2tfaWQpLCBtZXRob2Q9IkdFVCIpCiAgICBleGNlcHQgZmMuRmNFcnJvciBhcyBl
  >> "!B64TMP!" echo OgogICAgICAgIHByaW50KGYiTU9OSVRPUiBDSEVDSyBGQUlMRUQgZm9yIHttb25pdG9yX2lkfS97
  >> "!B64TMP!" echo Y2hlY2tfaWR9OiB7ZX0iLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBp
  >> "!B64TMP!" echo ZiBlLmhpbnQ6CiAgICAgICAgICAgIHByaW50KGUuaGludCwgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgIHJldHVybiAxCgogICAgaWYgYXNfanNvbjoKICAgICAgICBwcmludChqc29uLmR1bXBzKGRh
  >> "!B64TMP!" echo dGEpKQogICAgICAgIHJldHVybiAwCiAgICBwcmludChqc29uLmR1bXBzKGRhdGEsIGluZGVudD0y
  >> "!B64TMP!" echo KSkKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0
  >> "!B64TMP!" echo KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_monitor_check.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_research_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_research_search.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_research_search.py" "!TARGET!\local-web-search\scripts\web_research_search.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_research_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_research_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS2278314517.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggcmVzZWFyY2ggcGFwZXJzIHZpYSB0aGUg
  >> "!B64TMP!" echo RmlyZWNyYXdsIHJlc2VhcmNoIGluZGV4ICh0aGUKZmlyZWNyYXdsX3Jlc2VhcmNoX3NlYXJjaF9w
  >> "!B64TMP!" echo YXBlcnMgTUNQIHRvb2wpOiBwYXBlciBtZXRhZGF0YSBhbmQgYWJzdHJhY3RzCmFjcm9zcyBiaW9t
  >> "!B64TMP!" echo ZWRpY2FsLCBsaWZlLXNjaWVuY2UsIGFuZCBjbGluaWNhbCBsaXRlcmF0dXJlIChQdWJNZWQsIGJp
  >> "!B64TMP!" echo b1J4aXYsCm1lZFJ4aXYpIGFsb25nc2lkZSBhclhpdiBhbmQgb3RoZXIgc2NpZW50aWZpYyBzb3Vy
  >> "!B64TMP!" echo Y2VzLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX3Jlc2VhcmNoX3NlYXJjaC5weSAiPHF1ZXJ5PiIg
  >> "!B64TMP!" echo Wy0tanNvbl0KClNlbGYtaGVhbGluZzogaWYgdGhlIGxvY2FsLXNlYXJjaCBzdGFjayBpcyB1bnJl
  >> "!B64TMP!" echo YWNoYWJsZSAoRG9ja2VyIGVuZ2luZSBvciB0aGUKY29udGFpbmVycyBhcmUgZG93biksIHRoaXMg
  >> "!B64TMP!" echo c2NyaXB0IGF1dG9tYXRpY2FsbHkgc3RhcnRzIHRoZW0gKHRoZSBzYW1lIGxvZ2ljCmFzIGVuc3Vy
  >> "!B64TMP!" echo ZV9zdGFjay5weSAvIFJ1bi5iYXQpIGFuZCByZXRyaWVzIHRoZSByZXF1ZXN0LiBDb25uZWN0aW9u
  >> "!B64TMP!" echo IGZhaWx1cmVzCnNlbGYtaGVhbCBvbmNlOyB0cmFuc2llbnQgNDI5LzV4eCBhbnN3ZXJzIGFyZSBy
  >> "!B64TMP!" echo ZXRyaWVkIHdpdGggYSBzaG9ydCBiYWNrb2ZmLgpZb3UgZG8gTk9UIG5lZWQgdG8gcnVuIGVuc3Vy
  >> "!B64TMP!" echo ZV9zdGFjay5weSBmaXJzdCDigJQganVzdCBydW4gdGhlIHNjcmlwdC4KClByaW50cyB0aGUgcmFu
  >> "!B64TMP!" echo a2VkIHBhcGVycyBleGFjdGx5IGxpa2UgdGhlIE1DUCB0b29sIGRvZXMg4oCUIGZvciBlYWNoIHBh
  >> "!B64TMP!" echo cGVyOgoKICAgICMjIFtwYXBlcklkXSB0aXRsZQogICAgQXV0aG9yczogbmFtZTsgbmFtZTsgK04g
  >> "!B64TMP!" echo bW9yZQogICAgYWJzdHJhY3QgKHVwIHRvIDYwMCBjaGFycykKClNldmVyYWwgZGlzdGluY3QgZnJh
  >> "!B64TMP!" echo bWluZ3Mgb2YgdGhlIHNhbWUgcXVlc3Rpb24gc3VyZmFjZSBkaWZmZXJlbnQgcGFwZXJzLgpJbnNw
  >> "!B64TMP!" echo ZWN0IG9uZSBwYXBlciB3aXRoIHdlYl9yZXNlYXJjaF9pbnNwZWN0LnB5LiBgLS1qc29uYCBwcmlu
  >> "!B64TMP!" echo dHMgdGhlIHJhdyBBUEkKcmVzcG9uc2UgaW5zdGVhZC4KCk5PVEU6IHJlc2VhcmNoIHRvb2xzIG5l
  >> "!B64TMP!" echo ZWQgYSBGaXJlY3Jhd2wgYWNjb3VudCB3aXRoIHJlc2VhcmNoIHBlcm1pc3Npb25zCihzZXQgRklS
  >> "!B64TMP!" echo RUNSQVdMX0FQSV9LRVksIGFuZCBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczovL2FwaS5maXJlY3Jh
  >> "!B64TMP!" echo d2wuZGV2IGZvcgp0aGUgY2xvdWQgQVBJKTsgdGhlIHNlbGYtaG9zdGVkIHN0YWNrIG1heSBub3Qg
  >> "!B64TMP!" echo ZXhwb3NlIHRoZW0uCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN5cwoKc3lzLnBh
  >> "!B64TMP!" echo dGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgoX19maWxlX18pKSkK
  >> "!B64TMP!" echo aW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNyYXdsIEhUVFAgY2xp
  >> "!B64TMP!" echo ZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL3Jlc2VhcmNoL3NlYXJjaC9w
  >> "!B64TMP!" echo YXBlcnMiKQoKTUFYX0FVVEhPUlMgPSAxNQpNQVhfQUJTVFJBQ1RfQ0hBUlMgPSA2MDAKTUFYX0FG
  >> "!B64TMP!" echo RklMX0NIQVJTID0gNjAKTUFYX0FVVEhPUlNfTElORV9DSEFSUyA9IDQwMAoKCmRlZiBkaXNwbGF5
  >> "!B64TMP!" echo X2lkKHBhcGVyKToKICAgIHJldHVybiBwYXBlci5nZXQoInByaW1hcnlJZCIpIG9yIHBhcGVyLmdl
  >> "!B64TMP!" echo dCgicGFwZXJJZCIpIG9yICJtaXNzaW5nLXByaW1hcnktaWQiCgoKZGVmIGZtdF9hdXRob3JzKGF1
  >> "!B64TMP!" echo dGhvcnMpOgogICAgIiIiYEF1dGhvcnM6IGE7IGIgKGFmZmlsaWF0aW9uKTsgK04gbW9yZWAgb3Ig
  >> "!B64TMP!" echo Tm9uZSAobWlycm9ycyB0aGUgTUNQIHRvb2wpLiIiIgogICAgaWYgbm90IGF1dGhvcnM6CiAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIE5vbmUKICAgIGlmIGlzaW5zdGFuY2UoYXV0aG9ycywgc3RyKToKICAgICAgICBu
  >> "!B64TMP!" echo YW1lcyA9IFtzLnN0cmlwKCkgZm9yIHMgaW4gYXV0aG9ycy5zcGxpdCgiLCIpIGlmIHMuc3RyaXAo
  >> "!B64TMP!" echo KV0KICAgICAgICBpZiBub3QgbmFtZXM6CiAgICAgICAgICAgIHJldHVybiBOb25lCiAgICAgICAg
  >> "!B64TMP!" echo dG90YWwsIHNob3duID0gbGVuKG5hbWVzKSwgbmFtZXNbOk1BWF9BVVRIT1JTXQogICAgZWxzZToK
  >> "!B64TMP!" echo ICAgICAgICBpZiBub3QgaXNpbnN0YW5jZShhdXRob3JzLCBsaXN0KSBvciBub3QgYXV0aG9yczoK
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIE5vbmUKICAgICAgICB0b3RhbCA9IGxlbihhdXRob3JzKQogICAg
  >> "!B64TMP!" echo ICAgIHNob3duID0gW10KICAgICAgICBmb3IgYSBpbiBhdXRob3JzWzpNQVhfQVVUSE9SU106CiAg
  >> "!B64TMP!" echo ICAgICAgICAgIGlmIGlzaW5zdGFuY2UoYSwgZGljdCk6CiAgICAgICAgICAgICAgICBhZmYgPSAo
  >> "!B64TMP!" echo YS5nZXQoImFmZmlsaWF0aW9uIikgb3IgIiIpLnN0cmlwKCkKICAgICAgICAgICAgICAgIG5hbWUg
  >> "!B64TMP!" echo PSBhLmdldCgibmFtZSIpIG9yICI/IgogICAgICAgICAgICAgICAgc2hvd24uYXBwZW5kKCJ7fSAo
  >> "!B64TMP!" echo e30pIi5mb3JtYXQobmFtZSwgYWZmWzpNQVhfQUZGSUxfQ0hBUlNdKQogICAgICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgIGlmIGFmZiBlbHNlIG5hbWUpCiAgICAgICAgICAgIGVsc2U6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICBzaG93bi5hcHBlbmQoc3RyKGEpKQogICAgZXh0cmEgPSAiOyAre30gbW9yZSIuZm9y
  >> "!B64TMP!" echo bWF0KHRvdGFsIC0gTUFYX0FVVEhPUlMpIGlmIHRvdGFsID4gTUFYX0FVVEhPUlMgXAogICAgICAg
  >> "!B64TMP!" echo IGVsc2UgIiIKICAgIHJldHVybiAoIkF1dGhvcnM6ICIgKyAiOyAiLmpvaW4oc2hvd24pICsgZXh0
  >> "!B64TMP!" echo cmEpWzpNQVhfQVVUSE9SU19MSU5FX0NIQVJTXQoKCmRlZiBmbXRfaGl0cyhyZXN1bHRzKToKICAg
  >> "!B64TMP!" echo ICIiIkZvcm1hdCByYW5rZWQgcGFwZXIgcmVzdWx0cyAobWlycm9ycyB0aGUgTUNQIHRvb2wncyBm
  >> "!B64TMP!" echo b3JtYXR0ZXIpLiIiIgogICAgaWYgbm90IHJlc3VsdHM6CiAgICAgICAgcmV0dXJuICIobm8gcmVz
  >> "!B64TMP!" echo dWx0cykiCiAgICBibG9ja3MgPSBbXQogICAgZm9yIHIgaW4gcmVzdWx0czoKICAgICAgICBpZiBu
  >> "!B64TMP!" echo b3QgaXNpbnN0YW5jZShyLCBkaWN0KToKICAgICAgICAgICAgYmxvY2tzLmFwcGVuZChzdHIocikp
  >> "!B64TMP!" echo CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgbGluZXMgPSBbIiMjIFt7fV0ge30iLmZvcm1h
  >> "!B64TMP!" echo dChkaXNwbGF5X2lkKHIpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgci5n
  >> "!B64TMP!" echo ZXQoInRpdGxlIikgb3IgIih1bnRpdGxlZCkiKV0KICAgICAgICBhdXRob3JzID0gZm10X2F1dGhv
  >> "!B64TMP!" echo cnMoci5nZXQoImF1dGhvcnMiKSkKICAgICAgICBpZiBhdXRob3JzOgogICAgICAgICAgICBsaW5l
  >> "!B64TMP!" echo cy5hcHBlbmQoYXV0aG9ycykKICAgICAgICBhYnN0cmFjdCA9IChyLmdldCgiYWJzdHJhY3QiKSBv
  >> "!B64TMP!" echo ciAiKG5vIGFic3RyYWN0KSIpCiAgICAgICAgYWJzdHJhY3QgPSAiICIuam9pbihhYnN0cmFjdC5z
  >> "!B64TMP!" echo cGxpdCgpKVs6TUFYX0FCU1RSQUNUX0NIQVJTXQogICAgICAgIGxpbmVzLmFwcGVuZChhYnN0cmFj
  >> "!B64TMP!" echo dCkKICAgICAgICBibG9ja3MuYXBwZW5kKCJcbiIuam9pbihsaW5lcykpCiAgICByZXR1cm4gIlxu
  >> "!B64TMP!" echo XG4iLmpvaW4oYmxvY2tzKQoKCmRlZiBleHRyYWN0X3Jlc3VsdHMoZGF0YSk6CiAgICAiIiJGaW5k
  >> "!B64TMP!" echo IHRoZSBwYXBlci1yZXN1bHQgbGlzdCBpbiB0aGUgQVBJIHJlc3BvbnNlLiIiIgogICAgcmVzdWx0
  >> "!B64TMP!" echo cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIikKICAgIGlmIGlzaW5zdGFuY2UocmVzdWx0cywgbGlzdCk6
  >> "!B64TMP!" echo CiAgICAgICAgcmV0dXJuIHJlc3VsdHMKICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0YSIpCiAg
  >> "!B64TMP!" echo ICBpZiBpc2luc3RhbmNlKHBheWxvYWQsIGRpY3QpIGFuZCBpc2luc3RhbmNlKHBheWxvYWQuZ2V0
  >> "!B64TMP!" echo KCJyZXN1bHRzIiksIGxpc3QpOgogICAgICAgIHJldHVybiBwYXlsb2FkWyJyZXN1bHRzIl0KICAg
  >> "!B64TMP!" echo IGlmIGlzaW5zdGFuY2UoZGF0YSwgbGlzdCk6CiAgICAgICAgcmV0dXJuIGRhdGEKICAgIHJldHVy
  >> "!B64TMP!" echo biBbXQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IFthIGZvciBhIGluIHN5cy5hcmd2
  >> "!B64TMP!" echo WzE6XSBpZiBhICE9ICItLWpzb24iXQogICAgYXNfanNvbiA9ICItLWpzb24iIGluIHN5cy5hcmd2
  >> "!B64TMP!" echo WzE6XQogICAgcXVlcnkgPSAiICIuam9pbihhcmdzKS5zdHJpcCgpCiAgICBpZiBub3QgcXVlcnk6
  >> "!B64TMP!" echo CiAgICAgICAgcHJpbnQoJ3VzYWdlOiB3ZWJfcmVzZWFyY2hfc2VhcmNoLnB5ICI8cXVlcnk+IiBb
  >> "!B64TMP!" echo LS1qc29uXScsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgoKICAgIHRyeToKICAg
  >> "!B64TMP!" echo ICAgICBkYXRhID0gZmMuY2FsbCgiL3YxL3Jlc2VhcmNoL3NlYXJjaC9wYXBlcnMiLCBtZXRob2Q9
  >> "!B64TMP!" echo IlBPU1QiLAogICAgICAgICAgICAgICAgICAgICAgIGJvZHk9eyJxdWVyeSI6IHF1ZXJ5fSkKICAg
  >> "!B64TMP!" echo IGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJSRVNFQVJDSCBTRUFSQ0gg
  >> "!B64TMP!" echo RkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAg
  >> "!B64TMP!" echo ICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAg
  >> "!B64TMP!" echo IGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1
  >> "!B64TMP!" echo cm4gMAogICAgcHJpbnQoZm10X2hpdHMoZXh0cmFjdF9yZXN1bHRzKGRhdGEpKSkKICAgIHJldHVy
  >> "!B64TMP!" echo biAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_research_search.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_research_inspect.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_research_inspect.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_research_inspect.py" "!TARGET!\local-web-search\scripts\web_research_inspect.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_research_inspect.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_research_inspect.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1065362198.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJJbnNwZWN0IG9uZSByZXNlYXJjaCBwYXBlciB2aWEg
  >> "!B64TMP!" echo dGhlIEZpcmVjcmF3bCByZXNlYXJjaCBpbmRleCAodGhlCmZpcmVjcmF3bF9yZXNlYXJjaF9pbnNw
  >> "!B64TMP!" echo ZWN0X3BhcGVyIE1DUCB0b29sKTogY2Fub25pY2FsIG1ldGFkYXRhIGZvciBhIHBhcGVyCklEIHN1
  >> "!B64TMP!" echo Y2ggYXMgYW4gYXJYaXYsIFBNQywgUE1JRCwgb3IgRE9JIGlkZW50aWZpZXIuCgpVc2FnZToKICAg
  >> "!B64TMP!" echo IHB5dGhvbiB3ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSA8cGFwZXJJZD4gWy0tanNvbl0KCkV4YW1w
  >> "!B64TMP!" echo bGVzOgogICAgcHl0aG9uIHdlYl9yZXNlYXJjaF9pbnNwZWN0LnB5IGFyeGl2OjE3MDYuMDM3NjIK
  >> "!B64TMP!" echo ICAgIHB5dGhvbiB3ZWJfcmVzZWFyY2hfaW5zcGVjdC5weSBkb2k6MTAuMTAxNi9qLm5ldW5ldC4y
  >> "!B64TMP!" echo MDI1LjEwODA5NQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVu
  >> "!B64TMP!" echo cmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhp
  >> "!B64TMP!" echo cyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5z
  >> "!B64TMP!" echo dXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rp
  >> "!B64TMP!" echo b24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJl
  >> "!B64TMP!" echo IHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5z
  >> "!B64TMP!" echo dXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIHRoZSBw
  >> "!B64TMP!" echo YXBlcidzIG1ldGFkYXRhIGV4YWN0bHkgbGlrZSB0aGUgTUNQIHRvb2wgZG9lczoKCiAgICAjIHRp
  >> "!B64TMP!" echo dGxlCiAgICBQYXBlciBJRDogLi4uCiAgICBJRHM6IG5hbWVzcGFjZTp2YWx1ZSwgLi4uCiAgICBB
  >> "!B64TMP!" echo dXRob3JzOiAuLi4KICAgIENhdGVnb3JpZXM6IC4uLgogICAgRGF0ZXM6IGNyZWF0ZWQgLi4uOyB1
  >> "!B64TMP!" echo cGRhdGVkIC4uLgogICAgIyMgQWJzdHJhY3QKICAgIC4uLgoKRmluZCBwYXBlcnMgdG8gaW5zcGVj
  >> "!B64TMP!" echo dCB3aXRoIHdlYl9yZXNlYXJjaF9zZWFyY2gucHkuIGAtLWpzb25gIHByaW50cyB0aGUgcmF3CkFQ
  >> "!B64TMP!" echo SSByZXNwb25zZSBpbnN0ZWFkLgoKTk9URTogcmVzZWFyY2ggdG9vbHMgbmVlZCBhIEZpcmVjcmF3
  >> "!B64TMP!" echo bCBhY2NvdW50IHdpdGggcmVzZWFyY2ggcGVybWlzc2lvbnMKKHNldCBGSVJFQ1JBV0xfQVBJX0tF
  >> "!B64TMP!" echo WSwgYW5kIEZJUkVDUkFXTF9BUElfVVJMPWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yCnRo
  >> "!B64TMP!" echo ZSBjbG91ZCBBUEkpOyB0aGUgc2VsZi1ob3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4K
  >> "!B64TMP!" echo IiIiCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCmltcG9ydCB1cmxsaWIucGFyc2UK
  >> "!B64TMP!" echo CnN5cy5wYXRoLmluc2VydCgwLCBvcy5wYXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmls
  >> "!B64TMP!" echo ZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xfYXBpIGFzIGZjICAjIHNpYmxpbmc6IEZpcmVjcmF3bCBI
  >> "!B64TMP!" echo VFRQIGNsaWVudCArIHNlbGYtaGVhbAppbXBvcnQgd2ViX3Jlc2VhcmNoX3NlYXJjaCAgIyBzaWJs
  >> "!B64TMP!" echo aW5nOiBzaGFyZWQgcGFwZXIgZm9ybWF0dGVycwoKRU5EUE9JTlQgPSBmYy51cmwoIi92MS9yZXNl
  >> "!B64TMP!" echo YXJjaC9wYXBlcnMiKQoKCmRlZiBmbXRfcGFwZXJfbWV0YWRhdGEocGFwZXIpOgogICAgIiIiRm9y
  >> "!B64TMP!" echo bWF0IG9uZSBwYXBlcidzIG1ldGFkYXRhIChtaXJyb3JzIHRoZSBNQ1AgdG9vbCdzIGZvcm1hdHRl
  >> "!B64TMP!" echo cikuIiIiCiAgICBpZiBub3QgcGFwZXI6CiAgICAgICAgcmV0dXJuICIocGFwZXIgbm90IGZvdW5k
  >> "!B64TMP!" echo KSIKICAgIGxpbmVzID0gWyIjICIgKyAocGFwZXIuZ2V0KCJ0aXRsZSIpIG9yICIodW50aXRsZWQp
  >> "!B64TMP!" echo IiksICIiXQogICAgbGluZXMuYXBwZW5kKCJQYXBlciBJRDoge30iLmZvcm1hdChwYXBlci5nZXQo
  >> "!B64TMP!" echo InBhcGVySWQiKSBvciAiPyIpKQogICAgaWRzID0gW10KICAgIGZvciBuYW1lc3BhY2UsIHZhbHVl
  >> "!B64TMP!" echo cyBpbiAocGFwZXIuZ2V0KCJpZHMiKSBvciB7fSkuaXRlbXMoKToKICAgICAgICBpZiBpc2luc3Rh
  >> "!B64TMP!" echo bmNlKHZhbHVlcywgbGlzdCk6CiAgICAgICAgICAgIGlkcy5leHRlbmQoInt9Ont9Ii5mb3JtYXQo
  >> "!B64TMP!" echo bmFtZXNwYWNlLCB2KSBmb3IgdiBpbiB2YWx1ZXMpCiAgICAgICAgZWxpZiB2YWx1ZXMgaXMgbm90
  >> "!B64TMP!" echo IE5vbmU6CiAgICAgICAgICAgIGlkcy5hcHBlbmQoInt9Ont9Ii5mb3JtYXQobmFtZXNwYWNlLCB2
  >> "!B64TMP!" echo YWx1ZXMpKQogICAgaWYgaWRzOgogICAgICAgIGxpbmVzLmFwcGVuZCgiSURzOiAiICsgIiwgIi5q
  >> "!B64TMP!" echo b2luKGlkcykpCiAgICBhdXRob3JzID0gd2ViX3Jlc2VhcmNoX3NlYXJjaC5mbXRfYXV0aG9ycyhw
  >> "!B64TMP!" echo YXBlci5nZXQoImF1dGhvcnMiKSkKICAgIGlmIGF1dGhvcnM6CiAgICAgICAgbGluZXMuYXBwZW5k
  >> "!B64TMP!" echo KGF1dGhvcnMpCiAgICBjYXRlZ29yaWVzID0gcGFwZXIuZ2V0KCJjYXRlZ29yaWVzIikKICAgIGlm
  >> "!B64TMP!" echo IGlzaW5zdGFuY2UoY2F0ZWdvcmllcywgbGlzdCkgYW5kIGNhdGVnb3JpZXM6CiAgICAgICAgbGlu
  >> "!B64TMP!" echo ZXMuYXBwZW5kKCJDYXRlZ29yaWVzOiAiICsgIiwgIi5qb2luKHN0cihjKSBmb3IgYyBpbiBjYXRl
  >> "!B64TMP!" echo Z29yaWVzKSkKICAgIGRhdGVzID0gW10KICAgIGlmIHBhcGVyLmdldCgiY3JlYXRlZERhdGUiKToK
  >> "!B64TMP!" echo ICAgICAgICBkYXRlcy5hcHBlbmQoImNyZWF0ZWQgIiArIHN0cihwYXBlclsiY3JlYXRlZERhdGUi
  >> "!B64TMP!" echo XSkpCiAgICBpZiBwYXBlci5nZXQoInVwZGF0ZURhdGUiKToKICAgICAgICBkYXRlcy5hcHBlbmQo
  >> "!B64TMP!" echo InVwZGF0ZWQgIiArIHN0cihwYXBlclsidXBkYXRlRGF0ZSJdKSkKICAgIGlmIGRhdGVzOgogICAg
  >> "!B64TMP!" echo ICAgIGxpbmVzLmFwcGVuZCgiRGF0ZXM6ICIgKyAiOyAiLmpvaW4oZGF0ZXMpKQogICAgbGluZXMu
  >> "!B64TMP!" echo YXBwZW5kKCIiKQogICAgbGluZXMuYXBwZW5kKCIjIyBBYnN0cmFjdCIpCiAgICBsaW5lcy5hcHBl
  >> "!B64TMP!" echo bmQoIiAiLmpvaW4oKHBhcGVyLmdldCgiYWJzdHJhY3QiKSBvciAiKG5vIGFic3RyYWN0KSIpLnNw
  >> "!B64TMP!" echo bGl0KCkpKQogICAgcmV0dXJuICJcbiIuam9pbihsaW5lcykKCgpkZWYgZXh0cmFjdF9wYXBlcihk
  >> "!B64TMP!" echo YXRhKToKICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5n
  >> "!B64TMP!" echo ZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRhCiAgICBwYXBlciA9IHBheWxvYWQuZ2V0KCJwYXBl
  >> "!B64TMP!" echo ciIpCiAgICBpZiBpc2luc3RhbmNlKHBhcGVyLCBkaWN0KToKICAgICAgICByZXR1cm4gcGFwZXIK
  >> "!B64TMP!" echo ICAgIGlmIGlzaW5zdGFuY2UocGF5bG9hZCwgZGljdCkgYW5kIChwYXlsb2FkLmdldCgicGFwZXJJ
  >> "!B64TMP!" echo ZCIpIG9yIHBheWxvYWQuZ2V0KCJ0aXRsZSIpKToKICAgICAgICByZXR1cm4gcGF5bG9hZAogICAg
  >> "!B64TMP!" echo cmV0dXJuIE5vbmUKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBbYSBmb3IgYSBpbiBz
  >> "!B64TMP!" echo eXMuYXJndlsxOl0gaWYgYSAhPSAiLS1qc29uIl0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBz
  >> "!B64TMP!" echo eXMuYXJndlsxOl0KICAgIGlmIGxlbihhcmdzKSAhPSAxIG9yIGFyZ3NbMF0uc3RhcnRzd2l0aCgi
  >> "!B64TMP!" echo LS0iKToKICAgICAgICBwcmludCgidXNhZ2U6IHdlYl9yZXNlYXJjaF9pbnNwZWN0LnB5IDxwYXBl
  >> "!B64TMP!" echo cklkPiBbLS1qc29uXSIsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMgogICAgcGFw
  >> "!B64TMP!" echo ZXJfaWQgPSBhcmdzWzBdCgogICAgcGF0aCA9ICIvdjEvcmVzZWFyY2gvcGFwZXJzLyIgKyB1cmxs
  >> "!B64TMP!" echo aWIucGFyc2UucXVvdGUocGFwZXJfaWQsIHNhZmU9IiIpCiAgICB0cnk6CiAgICAgICAgZGF0YSA9
  >> "!B64TMP!" echo IGZjLmNhbGwocGF0aCwgbWV0aG9kPSJHRVQiKQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToK
  >> "!B64TMP!" echo ICAgICAgICBwcmludChmIlJFU0VBUkNIIElOU1BFQ1QgRkFJTEVEIGZvciB7cGFwZXJfaWR9OiB7
  >> "!B64TMP!" echo ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pz
  >> "!B64TMP!" echo b246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAg
  >> "!B64TMP!" echo cHJpbnQoZm10X3BhcGVyX21ldGFkYXRhKGV4dHJhY3RfcGFwZXIoZGF0YSkpKQogICAgcmV0dXJu
  >> "!B64TMP!" echo IDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgc3lzLmV4aXQobWFpbigpKQo=
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_research_inspect.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_research_related.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_research_related.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_research_related.py" "!TARGET!\local-web-search\scripts\web_research_related.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_research_related.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_research_related.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS293208104.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJGaW5kIHJlc2VhcmNoIHBhcGVycyByZWxhdGVkIHRv
  >> "!B64TMP!" echo IHNlZWQgcGFwZXJzIHZpYSB0aGUgRmlyZWNyYXdsIGNpdGF0aW9uCmdyYXBoICh0aGUgZmlyZWNy
  >> "!B64TMP!" echo YXdsX3Jlc2VhcmNoX3JlbGF0ZWRfcGFwZXJzIE1DUCB0b29sKS4KClVzYWdlOgogICAgcHl0aG9u
  >> "!B64TMP!" echo IHdlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IDxzZWVkSWQ+IFtzZWVkSWQgLi4uXSAtLWludGVudCAi
  >> "!B64TMP!" echo d2hhdCB0byByYW5rIGZvciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBbLS1t
  >> "!B64TMP!" echo b2RlIHNpbWlsYXJ8Y2l0ZXJzfHJlZmVyZW5jZXNdIFstLWpzb25dCgpTZWxmLWhlYWxpbmc6IGlm
  >> "!B64TMP!" echo IHRoZSBsb2NhbC1zZWFyY2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3Ig
  >> "!B64TMP!" echo dGhlCmNvbnRhaW5lcnMgYXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0
  >> "!B64TMP!" echo cyB0aGVtICh0aGUgc2FtZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQg
  >> "!B64TMP!" echo cmV0cmllcyB0aGUgcmVxdWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsg
  >> "!B64TMP!" echo dHJhbnNpZW50IDQyOS81eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29m
  >> "!B64TMP!" echo Zi4KWW91IGRvIE5PVCBuZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3Qg
  >> "!B64TMP!" echo cnVuIHRoZSBzY3JpcHQuCgpPbmUgdG8gdGVuIHNlZWQgcGFwZXIgSURzIChwb3NpdGlvbmFsKTsg
  >> "!B64TMP!" echo dGhlIGZpcnN0IGlzIHRoZSBwcmltYXJ5IHNlZWQsIHRoZQpyZXN0IGFyZSBhbmNob3JzLiBgLS1p
  >> "!B64TMP!" echo bnRlbnRgIChyZXF1aXJlZCkgaXMgYSBzaG9ydCBuYXR1cmFsLWxhbmd1YWdlCmRlc2NyaXB0aW9u
  >> "!B64TMP!" echo IHRoYXQgcmFua3MgdGhlIGNhbmRpZGF0ZXMuIGAtLW1vZGVgIGRlZmF1bHRzIHRvIGBzaW1pbGFy
  >> "!B64TMP!" echo YAooY28tY2l0YXRpb24gLyBiaWJsaW9ncmFwaGljIGNvdXBsaW5nKTsgYGNpdGVyc2AgcmV0dXJu
  >> "!B64TMP!" echo cyBwYXBlcnMgY2l0aW5nIGEKc2VlZCwgYHJlZmVyZW5jZXNgIHBhcGVycyBjaXRlZCBieSBhIHNl
  >> "!B64TMP!" echo ZWQuCgpQcmludHMgdGhlIHJhbmtlZCBjYW5kaWRhdGVzIGxpa2Ugd2ViX3Jlc2VhcmNoX3NlYXJj
  >> "!B64TMP!" echo aC5weSwgdGhlbgpgKHBvb2xTaXplPU4pYCBhbmQgYW55IGBub3RlOmAgZnJvbSB0aGUgQVBJLiBg
  >> "!B64TMP!" echo LS1qc29uYCBwcmludHMgdGhlIHJhdyBBUEkKcmVzcG9uc2UgaW5zdGVhZC4KCk5PVEU6IHJlc2Vh
  >> "!B64TMP!" echo cmNoIHRvb2xzIG5lZWQgYSBGaXJlY3Jhd2wgYWNjb3VudCB3aXRoIHJlc2VhcmNoIHBlcm1pc3Np
  >> "!B64TMP!" echo b25zCihzZXQgRklSRUNSQVdMX0FQSV9LRVksIGFuZCBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczov
  >> "!B64TMP!" echo L2FwaS5maXJlY3Jhd2wuZGV2IGZvcgp0aGUgY2xvdWQgQVBJKTsgdGhlIHNlbGYtaG9zdGVkIHN0
  >> "!B64TMP!" echo YWNrIG1heSBub3QgZXhwb3NlIHRoZW0uCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0
  >> "!B64TMP!" echo IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgo
  >> "!B64TMP!" echo X19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNy
  >> "!B64TMP!" echo YXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCmltcG9ydCB3ZWJfcmVzZWFyY2hfc2VhcmNoICAj
  >> "!B64TMP!" echo IHNpYmxpbmc6IHNoYXJlZCBwYXBlciBmb3JtYXR0ZXJzCgpFTkRQT0lOVCA9IGZjLnVybCgiL3Yx
  >> "!B64TMP!" echo L3Jlc2VhcmNoL3JlbGF0ZWQiKQoKTU9ERVMgPSAoInNpbWlsYXIiLCAiY2l0ZXJzIiwgInJlZmVy
  >> "!B64TMP!" echo ZW5jZXMiKQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXJncyA9IHN5cy5hcmd2WzE6XQogICAg
  >> "!B64TMP!" echo c2VlZHMsIGludGVudCwgbW9kZSwgYXNfanNvbiA9IFtdLCBOb25lLCBOb25lLCBGYWxzZQogICAg
  >> "!B64TMP!" echo aSA9IDAKICAgIHdoaWxlIGkgPCBsZW4oYXJncyk6CiAgICAgICAgYSA9IGFyZ3NbaV0KICAgICAg
  >> "!B64TMP!" echo ICBpZiBhID09ICItLWludGVudCIgYW5kIGkgKyAxIDwgbGVuKGFyZ3MpOgogICAgICAgICAgICBp
  >> "!B64TMP!" echo ICs9IDEKICAgICAgICAgICAgaW50ZW50ID0gYXJnc1tpXQogICAgICAgIGVsaWYgYSA9PSAiLS1t
  >> "!B64TMP!" echo b2RlIiBhbmQgaSArIDEgPCBsZW4oYXJncyk6CiAgICAgICAgICAgIGkgKz0gMQogICAgICAgICAg
  >> "!B64TMP!" echo ICBtb2RlID0gYXJnc1tpXQogICAgICAgICAgICBpZiBtb2RlIG5vdCBpbiBNT0RFUzoKICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgIHByaW50KGYiaW52YWxpZCAtLW1vZGU6IHttb2RlfSAob25lIG9mIHsnLCAnLmpv
  >> "!B64TMP!" echo aW4oTU9ERVMpfSkiLAogICAgICAgICAgICAgICAgICAgICAgZmlsZT1zeXMuc3RkZXJyKQogICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbGlmIGEgPT0gIi0tanNvbiI6CiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGFzX2pzb24gPSBUcnVlCiAgICAgICAgZWxpZiBhLnN0YXJ0c3dpdGgoIi0tIik6CiAgICAg
  >> "!B64TMP!" echo ICAgICAgIHByaW50KGYidW5rbm93biBvcHRpb246IHthfSIsIGZpbGU9c3lzLnN0ZGVycikKICAg
  >> "!B64TMP!" echo ICAgICAgICAgcmV0dXJuIDIKICAgICAgICBlbHNlOgogICAgICAgICAgICBzZWVkcy5hcHBlbmQo
  >> "!B64TMP!" echo YSkKICAgICAgICBpICs9IDEKCiAgICBpZiBub3Qgc2VlZHMgb3Igbm90IGludGVudDoKICAgICAg
  >> "!B64TMP!" echo ICBwcmludCgndXNhZ2U6IHdlYl9yZXNlYXJjaF9yZWxhdGVkLnB5IDxzZWVkSWQ+IFtzZWVkSWQg
  >> "!B64TMP!" echo Li4uXSAnCiAgICAgICAgICAgICAgJy0taW50ZW50ICJ3aGF0IHRvIHJhbmsgZm9yIiAnCiAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgJ1stLW1vZGUgc2ltaWxhcnxjaXRlcnN8cmVmZXJlbmNlc10gWy0tanNvbl0nLCBm
  >> "!B64TMP!" echo aWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuIDIKICAgIGlmIG5vdCAxIDw9IGxlbihzZWVk
  >> "!B64TMP!" echo cykgPD0gMTA6CiAgICAgICAgcHJpbnQoInByb3ZpZGUgb25lIHRvIHRlbiBzZWVkIHBhcGVyIElE
  >> "!B64TMP!" echo cyAoZmlyc3QgaXMgdGhlIHByaW1hcnkgc2VlZCkiLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0
  >> "!B64TMP!" echo ZGVycikKICAgICAgICByZXR1cm4gMgoKICAgIGJvZHkgPSB7InNlZWRfaWRzIjogc2VlZHMsICJp
  >> "!B64TMP!" echo bnRlbnQiOiBpbnRlbnR9CiAgICBpZiBtb2RlOgogICAgICAgIGJvZHlbIm1vZGUiXSA9IG1vZGUK
  >> "!B64TMP!" echo CiAgICB0cnk6CiAgICAgICAgZGF0YSA9IGZjLmNhbGwoIi92MS9yZXNlYXJjaC9yZWxhdGVkIiwg
  >> "!B64TMP!" echo bWV0aG9kPSJQT1NUIiwgYm9keT1ib2R5KQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAg
  >> "!B64TMP!" echo ICAgICBwcmludChmIlJFU0VBUkNIIFJFTEFURUQgRkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRl
  >> "!B64TMP!" echo cnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lz
  >> "!B64TMP!" echo LnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQo
  >> "!B64TMP!" echo anNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAoKICAgIHBheWxvYWQgPSBkYXRhLmdl
  >> "!B64TMP!" echo dCgiZGF0YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgZWxzZSBkYXRh
  >> "!B64TMP!" echo CiAgICBwcmludCh3ZWJfcmVzZWFyY2hfc2VhcmNoLmZtdF9oaXRzKAogICAgICAgIHdlYl9yZXNl
  >> "!B64TMP!" echo YXJjaF9zZWFyY2guZXh0cmFjdF9yZXN1bHRzKGRhdGEpKSkKICAgIHBvb2xfc2l6ZSA9IHBheWxv
  >> "!B64TMP!" echo YWQuZ2V0KCJwb29sU2l6ZSIpIG9yIDAKICAgIHByaW50KGYiKHBvb2xTaXplPXtwb29sX3NpemV9
  >> "!B64TMP!" echo KSIpCiAgICBub3RlID0gcGF5bG9hZC5nZXQoIm5vdGUiKQogICAgaWYgbm90ZToKICAgICAgICBw
  >> "!B64TMP!" echo cmludChmIm5vdGU6IHtub3RlfSIpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21h
  >> "!B64TMP!" echo aW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_research_related.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_research_read.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_research_read.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_research_read.py" "!TARGET!\local-web-search\scripts\web_research_read.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_research_read.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_research_read.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS691893132.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJSZWFkIGluLWJvZHkgcGFzc2FnZXMgZnJvbSBvbmUg
  >> "!B64TMP!" echo cmVzZWFyY2ggcGFwZXIgdGhhdCBhcmUgcmVsZXZhbnQgdG8gYQpzcGVjaWZpYyBxdWVzdGlvbiAo
  >> "!B64TMP!" echo dGhlIGZpcmVjcmF3bF9yZXNlYXJjaF9yZWFkX3BhcGVyIE1DUCB0b29sKS4gRnVsbCB0ZXh0IGlz
  >> "!B64TMP!" echo CmF2YWlsYWJsZSBvbmx5IGZvciBpbmRleGVkIHBhcGVycy4KClVzYWdlOgogICAgcHl0aG9uIHdl
  >> "!B64TMP!" echo Yl9yZXNlYXJjaF9yZWFkLnB5IDxwYXBlcklkPiAiPHF1ZXN0aW9uPiIgWy0tanNvbl0KCkV4YW1w
  >> "!B64TMP!" echo bGU6CiAgICBweXRob24gd2ViX3Jlc2VhcmNoX3JlYWQucHkgYXJ4aXY6MTcwNi4wMzc2MiAiaG93
  >> "!B64TMP!" echo IGlzIGF0dGVudGlvbiBjb21wdXRlZD8iCgpTZWxmLWhlYWxpbmc6IGlmIHRoZSBsb2NhbC1zZWFy
  >> "!B64TMP!" echo Y2ggc3RhY2sgaXMgdW5yZWFjaGFibGUgKERvY2tlciBlbmdpbmUgb3IgdGhlCmNvbnRhaW5lcnMg
  >> "!B64TMP!" echo YXJlIGRvd24pLCB0aGlzIHNjcmlwdCBhdXRvbWF0aWNhbGx5IHN0YXJ0cyB0aGVtICh0aGUgc2Ft
  >> "!B64TMP!" echo ZSBsb2dpYwphcyBlbnN1cmVfc3RhY2sucHkgLyBSdW4uYmF0KSBhbmQgcmV0cmllcyB0aGUgcmVx
  >> "!B64TMP!" echo dWVzdC4gQ29ubmVjdGlvbiBmYWlsdXJlcwpzZWxmLWhlYWwgb25jZTsgdHJhbnNpZW50IDQyOS81
  >> "!B64TMP!" echo eHggYW5zd2VycyBhcmUgcmV0cmllZCB3aXRoIGEgc2hvcnQgYmFja29mZi4KWW91IGRvIE5PVCBu
  >> "!B64TMP!" echo ZWVkIHRvIHJ1biBlbnN1cmVfc3RhY2sucHkgZmlyc3Qg4oCUIGp1c3QgcnVuIHRoZSBzY3JpcHQu
  >> "!B64TMP!" echo CgpQcmludHMgdGhlIG1hdGNoaW5nIHBhc3NhZ2VzIHNlcGFyYXRlZCBieSBgLS0tYCBsaW5lcyAo
  >> "!B64TMP!" echo bGlrZSB0aGUgTUNQIHRvb2wpLCBvcgphIG5vdGljZSB3aGVuIG5vIGZ1bGwgdGV4dCBpcyBhdmFp
  >> "!B64TMP!" echo bGFibGUuIGAtLWpzb25gIHByaW50cyB0aGUgcmF3IEFQSQpyZXNwb25zZSBpbnN0ZWFkLgoKTk9U
  >> "!B64TMP!" echo RTogcmVzZWFyY2ggdG9vbHMgbmVlZCBhIEZpcmVjcmF3bCBhY2NvdW50IHdpdGggcmVzZWFyY2gg
  >> "!B64TMP!" echo cGVybWlzc2lvbnMKKHNldCBGSVJFQ1JBV0xfQVBJX0tFWSwgYW5kIEZJUkVDUkFXTF9BUElfVVJM
  >> "!B64TMP!" echo PWh0dHBzOi8vYXBpLmZpcmVjcmF3bC5kZXYgZm9yCnRoZSBjbG91ZCBBUEkpOyB0aGUgc2VsZi1o
  >> "!B64TMP!" echo b3N0ZWQgc3RhY2sgbWF5IG5vdCBleHBvc2UgdGhlbS4KIiIiCmltcG9ydCBqc29uCmltcG9ydCBv
  >> "!B64TMP!" echo cwppbXBvcnQgc3lzCmltcG9ydCB1cmxsaWIucGFyc2UKCnN5cy5wYXRoLmluc2VydCgwLCBvcy5w
  >> "!B64TMP!" echo YXRoLmRpcm5hbWUob3MucGF0aC5hYnNwYXRoKF9fZmlsZV9fKSkpCmltcG9ydCBmaXJlY3Jhd2xf
  >> "!B64TMP!" echo YXBpIGFzIGZjICAjIHNpYmxpbmc6IEZpcmVjcmF3bCBIVFRQIGNsaWVudCArIHNlbGYtaGVhbAoK
  >> "!B64TMP!" echo RU5EUE9JTlQgPSBmYy51cmwoIi92MS9yZXNlYXJjaC9wYXBlcnMiKQoKCmRlZiBtYWluKCkgLT4g
  >> "!B64TMP!" echo aW50OgogICAgYXJncyA9IFthIGZvciBhIGluIHN5cy5hcmd2WzE6XSBpZiBhICE9ICItLWpzb24i
  >> "!B64TMP!" echo XQogICAgYXNfanNvbiA9ICItLWpzb24iIGluIHN5cy5hcmd2WzE6XQogICAgaWYgbGVuKGFyZ3Mp
  >> "!B64TMP!" echo ICE9IDIgb3IgYXJnc1swXS5zdGFydHN3aXRoKCItLSIpIG9yIGFyZ3NbMV0uc3RhcnRzd2l0aCgi
  >> "!B64TMP!" echo LS0iKToKICAgICAgICBwcmludCgndXNhZ2U6IHdlYl9yZXNlYXJjaF9yZWFkLnB5IDxwYXBlcklk
  >> "!B64TMP!" echo PiAiPHF1ZXN0aW9uPiIgWy0tanNvbl0nLAogICAgICAgICAgICAgIGZpbGU9c3lzLnN0ZGVycikK
  >> "!B64TMP!" echo ICAgICAgICByZXR1cm4gMgogICAgcGFwZXJfaWQsIHF1ZXN0aW9uID0gYXJncwoKICAgIHBhdGgg
  >> "!B64TMP!" echo PSAoIi92MS9yZXNlYXJjaC9wYXBlcnMvIiArIHVybGxpYi5wYXJzZS5xdW90ZShwYXBlcl9pZCwg
  >> "!B64TMP!" echo c2FmZT0iIikKICAgICAgICAgICAgKyAiL3JlYWQiKQogICAgdHJ5OgogICAgICAgIGRhdGEgPSBm
  >> "!B64TMP!" echo Yy5jYWxsKHBhdGgsIG1ldGhvZD0iUE9TVCIsIGJvZHk9eyJxdWVzdGlvbiI6IHF1ZXN0aW9ufSkK
  >> "!B64TMP!" echo ICAgIGV4Y2VwdCBmYy5GY0Vycm9yIGFzIGU6CiAgICAgICAgcHJpbnQoZiJSRVNFQVJDSCBSRUFE
  >> "!B64TMP!" echo IEZBSUxFRCBmb3Ige3BhcGVyX2lkfToge2V9IiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIGlm
  >> "!B64TMP!" echo IGUuaGludDoKICAgICAgICAgICAgcHJpbnQoZS5oaW50LCBmaWxlPXN5cy5zdGRlcnIpCiAgICAg
  >> "!B64TMP!" echo ICAgcmV0dXJuIDEKCiAgICBpZiBhc19qc29uOgogICAgICAgIHByaW50KGpzb24uZHVtcHMoZGF0
  >> "!B64TMP!" echo YSkpCiAgICAgICAgcmV0dXJuIDAKCiAgICBwYXNzYWdlcyA9IGRhdGEuZ2V0KCJwYXNzYWdlcyIp
  >> "!B64TMP!" echo CiAgICBpZiBwYXNzYWdlcyBpcyBOb25lOgogICAgICAgIHBheWxvYWQgPSBkYXRhLmdldCgiZGF0
  >> "!B64TMP!" echo YSIpIGlmIGlzaW5zdGFuY2UoZGF0YS5nZXQoImRhdGEiKSwgZGljdCkgXAogICAgICAgICAgICBl
  >> "!B64TMP!" echo bHNlIGRhdGEKICAgICAgICBwYXNzYWdlcyA9IHBheWxvYWQuZ2V0KCJwYXNzYWdlcyIpCiAgICBp
  >> "!B64TMP!" echo ZiBub3QgaXNpbnN0YW5jZShwYXNzYWdlcywgbGlzdCkgb3Igbm90IHBhc3NhZ2VzOgogICAgICAg
  >> "!B64TMP!" echo IHByaW50KCIobm8gZnVsbC10ZXh0IHBhc3NhZ2VzIGF2YWlsYWJsZSBmb3IgdGhpcyBwYXBlciki
  >> "!B64TMP!" echo KQogICAgICAgIHJldHVybiAwCiAgICB0ZXh0cyA9IFtwLmdldCgidGV4dCIpIGlmIGlzaW5zdGFu
  >> "!B64TMP!" echo Y2UocCwgZGljdCkgZWxzZSBzdHIocCkKICAgICAgICAgICAgIGZvciBwIGluIHBhc3NhZ2VzXQog
  >> "!B64TMP!" echo ICAgcHJpbnQoIlxuLS0tXG4iLmpvaW4odCBmb3IgdCBpbiB0ZXh0cyBpZiB0KSkKICAgIHJldHVy
  >> "!B64TMP!" echo biAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4oKSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_research_read.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_github_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_github_search.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_github_search.py" "!TARGET!\local-web-search\scripts\web_github_search.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_github_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_github_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS1125861393.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggaW5kZXhlZCBwdWJsaWMgR2l0SHViIGlz
  >> "!B64TMP!" echo c3VlLCBwdWxsLXJlcXVlc3QsIGFuZCBSRUFETUUgY29udGVudCB2aWEKdGhlIEZpcmVjcmF3bCBy
  >> "!B64TMP!" echo ZXNlYXJjaCBpbmRleCAodGhlIGZpcmVjcmF3bF9yZXNlYXJjaF9zZWFyY2hfZ2l0aHViIE1DUAp0
  >> "!B64TMP!" echo b29sKS4KClVzYWdlOgogICAgcHl0aG9uIHdlYl9naXRodWJfc2VhcmNoLnB5ICI8cXVlcnk+IiBb
  >> "!B64TMP!" echo LS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2VhcmNoIHN0YWNrIGlzIHVucmVh
  >> "!B64TMP!" echo Y2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJzIGFyZSBkb3duKSwgdGhpcyBz
  >> "!B64TMP!" echo Y3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNhbWUgbG9naWMKYXMgZW5zdXJl
  >> "!B64TMP!" echo X3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJlcXVlc3QuIENvbm5lY3Rpb24g
  >> "!B64TMP!" echo ZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0MjkvNXh4IGFuc3dlcnMgYXJlIHJl
  >> "!B64TMP!" echo dHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1QgbmVlZCB0byBydW4gZW5zdXJl
  >> "!B64TMP!" echo X3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0LgoKUHJpbnRzIHRoZSByYW5r
  >> "!B64TMP!" echo ZWQgbWF0Y2hlcyBleGFjdGx5IGxpa2UgdGhlIE1DUCB0b29sIGRvZXMg4oCUIGZvciBlYWNoIGhp
  >> "!B64TMP!" echo dDoKCiAgICBbcmVwbyMxMjNdIChwdWxsX3JlcXVlc3QsIDUgc2VnbWVudHMpCiAgICBodHRwczov
  >> "!B64TMP!" echo L2dpdGh1Yi5jb20vLi4uCiAgICBtYXRjaGVkIGNvbnRlbnQgKHVwIHRvIDEyMDAgY2hhcnMpCgpg
  >> "!B64TMP!" echo LS1qc29uYCBwcmludHMgdGhlIHJhdyBBUEkgcmVzcG9uc2UgaW5zdGVhZC4KCk5PVEU6IHJlc2Vh
  >> "!B64TMP!" echo cmNoIHRvb2xzIG5lZWQgYSBGaXJlY3Jhd2wgYWNjb3VudCB3aXRoIHJlc2VhcmNoIHBlcm1pc3Np
  >> "!B64TMP!" echo b25zCihzZXQgRklSRUNSQVdMX0FQSV9LRVksIGFuZCBGSVJFQ1JBV0xfQVBJX1VSTD1odHRwczov
  >> "!B64TMP!" echo L2FwaS5maXJlY3Jhd2wuZGV2IGZvcgp0aGUgY2xvdWQgQVBJKTsgdGhlIHNlbGYtaG9zdGVkIHN0
  >> "!B64TMP!" echo YWNrIG1heSBub3QgZXhwb3NlIHRoZW0uCiIiIgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0
  >> "!B64TMP!" echo IHN5cwoKc3lzLnBhdGguaW5zZXJ0KDAsIG9zLnBhdGguZGlybmFtZShvcy5wYXRoLmFic3BhdGgo
  >> "!B64TMP!" echo X19maWxlX18pKSkKaW1wb3J0IGZpcmVjcmF3bF9hcGkgYXMgZmMgICMgc2libGluZzogRmlyZWNy
  >> "!B64TMP!" echo YXdsIEhUVFAgY2xpZW50ICsgc2VsZi1oZWFsCgpFTkRQT0lOVCA9IGZjLnVybCgiL3YxL3Jlc2Vh
  >> "!B64TMP!" echo cmNoL3NlYXJjaC9naXRodWIiKQoKTUFYX0NPTlRFTlRfQ0hBUlMgPSAxMjAwCgoKZGVmIGZtdF9n
  >> "!B64TMP!" echo aXRodWIocmVzdWx0cyk6CiAgICAiIiJGb3JtYXQgcmFua2VkIEdpdEh1YiBtYXRjaGVzIChtaXJy
  >> "!B64TMP!" echo b3JzIHRoZSBNQ1AgdG9vbCdzIGZvcm1hdHRlcikuIiIiCiAgICBpZiBub3QgcmVzdWx0czoKICAg
  >> "!B64TMP!" echo ICAgICByZXR1cm4gIihubyByZXN1bHRzKSIKICAgIGJsb2NrcyA9IFtdCiAgICBmb3IgciBpbiBy
  >> "!B64TMP!" echo ZXN1bHRzOgogICAgICAgIGlmIG5vdCBpc2luc3RhbmNlKHIsIGRpY3QpOgogICAgICAgICAgICBi
  >> "!B64TMP!" echo bG9ja3MuYXBwZW5kKHN0cihyKSkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBsaW5lcyA9
  >> "!B64TMP!" echo IFtdCiAgICAgICAgcmVwbyA9IHIuZ2V0KCJyZXBvIikgb3IgIj8iCiAgICAgICAgbnVtYmVyID0g
  >> "!B64TMP!" echo ci5nZXQoIm51bWJlciIpCiAgICAgICAgaWYgbnVtYmVyIGlzIE5vbmUgYW5kIHIuZ2V0KCJwYWdl
  >> "!B64TMP!" echo VHlwZSIpIGlzIE5vbmU6CiAgICAgICAgICAgIGxpbmVzLmFwcGVuZChmIlt7cmVwb31dIFJFQURN
  >> "!B64TMP!" echo RSIpCiAgICAgICAgZWxzZToKICAgICAgICAgICAgcmVmID0gZiIje251bWJlcn0iIGlmIG51bWJl
  >> "!B64TMP!" echo ciBpcyBub3QgTm9uZSBlbHNlICIiCiAgICAgICAgICAgIG1ldGFfcGFydHMgPSBbc3RyKHIuZ2V0
  >> "!B64TMP!" echo KCJwYWdlVHlwZSIpIG9yICIiKV0KICAgICAgICAgICAgaWYgci5nZXQoInNlZ21lbnRDb3VudCIp
  >> "!B64TMP!" echo OgogICAgICAgICAgICAgICAgbWV0YV9wYXJ0cy5hcHBlbmQoZiJ7clsnc2VnbWVudENvdW50J119
  >> "!B64TMP!" echo IHNlZ21lbnRzIikKICAgICAgICAgICAgbWV0YSA9ICIsICIuam9pbihwIGZvciBwIGluIG1ldGFf
  >> "!B64TMP!" echo cGFydHMgaWYgcCkKICAgICAgICAgICAgbGluZXMuYXBwZW5kKGYiW3tyZXBvfXtyZWZ9XSIgKyAo
  >> "!B64TMP!" echo ZiIgKHttZXRhfSkiIGlmIG1ldGEgZWxzZSAiIikpCiAgICAgICAgdXJsID0gci5nZXQoInJlYWRt
  >> "!B64TMP!" echo ZVVybCIpIG9yIHIuZ2V0KCJ1cmwiKQogICAgICAgIGlmIHVybDoKICAgICAgICAgICAgbGluZXMu
  >> "!B64TMP!" echo YXBwZW5kKHVybCkKICAgICAgICBib2R5ID0gKHIuZ2V0KCJjb250ZW50TWQiKSBvciByLmdldCgi
  >> "!B64TMP!" echo c25pcHBldCIpIG9yICIiKS5zdHJpcCgpCiAgICAgICAgbGluZXMuYXBwZW5kKGJvZHlbOk1BWF9D
  >> "!B64TMP!" echo T05URU5UX0NIQVJTXSBpZiBib2R5IGVsc2UgIihubyBjb250ZW50KSIpCiAgICAgICAgYmxvY2tz
  >> "!B64TMP!" echo LmFwcGVuZCgiXG4iLmpvaW4obGluZXMpKQogICAgcmV0dXJuICJcblxuIi5qb2luKGJsb2NrcykK
  >> "!B64TMP!" echo CgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFyZ3MgPSBbYSBmb3IgYSBpbiBzeXMuYXJndlsxOl0g
  >> "!B64TMP!" echo aWYgYSAhPSAiLS1qc29uIl0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBzeXMuYXJndlsxOl0K
  >> "!B64TMP!" echo ICAgIHF1ZXJ5ID0gIiAiLmpvaW4oYXJncykuc3RyaXAoKQogICAgaWYgbm90IHF1ZXJ5OgogICAg
  >> "!B64TMP!" echo ICAgIHByaW50KCd1c2FnZTogd2ViX2dpdGh1Yl9zZWFyY2gucHkgIjxxdWVyeT4iIFstLWpzb25d
  >> "!B64TMP!" echo JywgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAyCgogICAgdHJ5OgogICAgICAgIGRh
  >> "!B64TMP!" echo dGEgPSBmYy5jYWxsKCIvdjEvcmVzZWFyY2gvc2VhcmNoL2dpdGh1YiIsIG1ldGhvZD0iUE9TVCIs
  >> "!B64TMP!" echo CiAgICAgICAgICAgICAgICAgICAgICAgYm9keT17InF1ZXJ5IjogcXVlcnl9KQogICAgZXhjZXB0
  >> "!B64TMP!" echo IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIkdJVEhVQiBTRUFSQ0ggRkFJTEVEOiB7
  >> "!B64TMP!" echo ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50OgogICAgICAgICAgICBwcmlu
  >> "!B64TMP!" echo dChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4gMQoKICAgIGlmIGFzX2pz
  >> "!B64TMP!" echo b246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAgICByZXR1cm4gMAogICAg
  >> "!B64TMP!" echo cmVzdWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIikKICAgIGlmIHJlc3VsdHMgaXMgTm9uZToKICAg
  >> "!B64TMP!" echo ICAgICBwYXlsb2FkID0gZGF0YS5nZXQoImRhdGEiKSBpZiBpc2luc3RhbmNlKGRhdGEuZ2V0KCJk
  >> "!B64TMP!" echo YXRhIiksIGRpY3QpIFwKICAgICAgICAgICAgZWxzZSBkYXRhCiAgICAgICAgcmVzdWx0cyA9IHBh
  >> "!B64TMP!" echo eWxvYWQuZ2V0KCJyZXN1bHRzIikKICAgIGlmIG5vdCBpc2luc3RhbmNlKHJlc3VsdHMsIGxpc3Qp
  >> "!B64TMP!" echo OgogICAgICAgIHJlc3VsdHMgPSBbXQogICAgcHJpbnQoZm10X2dpdGh1YihyZXN1bHRzKSkKICAg
  >> "!B64TMP!" echo IHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHN5cy5leGl0KG1haW4o
  >> "!B64TMP!" echo KSkK
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_github_search.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)

REM --- local-web-search/scripts/web_developer_search.py ---
set "NEED_B64=1"
if exist "!SRC!\local-web-search\scripts\web_developer_search.py" (
  copy /Y "!SRC!\local-web-search\scripts\web_developer_search.py" "!TARGET!\local-web-search\scripts\web_developer_search.py" >nul 2>&1
  if exist "!TARGET!\local-web-search\scripts\web_developer_search.py" set "NEED_B64=0"
)
if "!NEED_B64!"=="1" (
  echo   [embedded] local-web-search/scripts/web_developer_search.py  ^(source not found next to installer; using built-in copy^)
  set "B64TMP=%TEMP%\LS4120898073.b64"
  > "!B64TMP!" echo IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTZWFyY2ggdGhlIEZpcmVjcmF3bCBkZXZlbG9wZXIg
  >> "!B64TMP!" echo aW5kZXgg4oCUIGJ1aWx0IGZvciBjb2RpbmcgYWdlbnRzLCBjb3ZlcmluZwpHaXRIdWIgaXNzdWVz
  >> "!B64TMP!" echo LCBtZXJnZWQgcHVsbCByZXF1ZXN0cywgcmVwb3NpdG9yeSBSRUFETUVzLCBhbmQgY3VyYXRlZApk
  >> "!B64TMP!" echo b2N1bWVudGF0aW9uIHNpdGVzICh0aGUgZmlyZWNyYXdsX2RldmVsb3Blcl9zZWFyY2ggTUNQIHRv
  >> "!B64TMP!" echo b2wpLgoKVXNhZ2U6CiAgICBweXRob24gd2ViX2RldmVsb3Blcl9zZWFyY2gucHkgIjxxdWVyeT4i
  >> "!B64TMP!" echo IFstLXNraWxscy1vbmx5XSBbLS1qc29uXQoKU2VsZi1oZWFsaW5nOiBpZiB0aGUgbG9jYWwtc2Vh
  >> "!B64TMP!" echo cmNoIHN0YWNrIGlzIHVucmVhY2hhYmxlIChEb2NrZXIgZW5naW5lIG9yIHRoZQpjb250YWluZXJz
  >> "!B64TMP!" echo IGFyZSBkb3duKSwgdGhpcyBzY3JpcHQgYXV0b21hdGljYWxseSBzdGFydHMgdGhlbSAodGhlIHNh
  >> "!B64TMP!" echo bWUgbG9naWMKYXMgZW5zdXJlX3N0YWNrLnB5IC8gUnVuLmJhdCkgYW5kIHJldHJpZXMgdGhlIHJl
  >> "!B64TMP!" echo cXVlc3QuIENvbm5lY3Rpb24gZmFpbHVyZXMKc2VsZi1oZWFsIG9uY2U7IHRyYW5zaWVudCA0Mjkv
  >> "!B64TMP!" echo NXh4IGFuc3dlcnMgYXJlIHJldHJpZWQgd2l0aCBhIHNob3J0IGJhY2tvZmYuCllvdSBkbyBOT1Qg
  >> "!B64TMP!" echo bmVlZCB0byBydW4gZW5zdXJlX3N0YWNrLnB5IGZpcnN0IOKAlCBqdXN0IHJ1biB0aGUgc2NyaXB0
  >> "!B64TMP!" echo LgoKVXNlIGl0IGZvciBkZXZlbG9wZXIgcXVlc3Rpb25zIOKAlCBjb2RlIGJlaGF2aW91ciwgYSBs
  >> "!B64TMP!" echo aWJyYXJ5IG9yIGZyYW1ld29yaywgYW4KQVBJIGNvbnRyYWN0LCBhbiBlcnJvciBtZXNzYWdlLCBv
  >> "!B64TMP!" echo ciBhIGtub3duIGJ1Zy4gYC0tc2tpbGxzLW9ubHlgIGxpbWl0cyB0aGUKc2VhcmNoIHRvIGFnZW50
  >> "!B64TMP!" echo LXNraWxsIGZpbGVzLiBQcmludHMgdGhlIHJhbmtlZCByZXN1bHRzIGV4YWN0bHkgbGlrZSB0aGUg
  >> "!B64TMP!" echo TUNQCnRvb2wgZG9lcyDigJQgZm9yIGVhY2ggaGl0OgoKICAgICMjIFtpZF0gKGtpbmQpIHRpdGxl
  >> "!B64TMP!" echo CiAgICBodHRwczovLy4uLgogICAgbWF0Y2hlZCBwYXNzYWdlcyAodXAgdG8gMTIwMCBjaGFycywg
  >> "!B64TMP!" echo c2VwYXJhdGVkIGJ5IC0tLSkKCmAtLWpzb25gIHByaW50cyB0aGUgcmF3IEFQSSByZXNwb25zZSBp
  >> "!B64TMP!" echo bnN0ZWFkLgoKTk9URTogZGV2ZWxvcGVyIHNlYXJjaCBuZWVkcyBhIEZpcmVjcmF3bCBhY2NvdW50
  >> "!B64TMP!" echo IHdpdGggZGV2ZWxvcGVyLXNlYXJjaApwZXJtaXNzaW9ucyAoc2V0IEZJUkVDUkFXTF9BUElfS0VZ
  >> "!B64TMP!" echo LCBhbmQKRklSRUNSQVdMX0FQSV9VUkw9aHR0cHM6Ly9hcGkuZmlyZWNyYXdsLmRldiBmb3IgdGhl
  >> "!B64TMP!" echo IGNsb3VkIEFQSSk7IHRoZQpzZWxmLWhvc3RlZCBzdGFjayBtYXkgbm90IGV4cG9zZSBpdC4KIiIi
  >> "!B64TMP!" echo CmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc3lzCgpzeXMucGF0aC5pbnNlcnQoMCwgb3Mu
  >> "!B64TMP!" echo cGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKQppbXBvcnQgZmlyZWNyYXds
  >> "!B64TMP!" echo X2FwaSBhcyBmYyAgIyBzaWJsaW5nOiBGaXJlY3Jhd2wgSFRUUCBjbGllbnQgKyBzZWxmLWhlYWwK
  >> "!B64TMP!" echo CkVORFBPSU5UID0gZmMudXJsKCIvdjEvZGV2ZWxvcGVyL3NlYXJjaCIpCgpNQVhfUEFTU0FHRV9D
  >> "!B64TMP!" echo SEFSUyA9IDEyMDAKCgpkZWYgZm10X2RldmVsb3BlcihyZXN1bHRzKToKICAgICIiIkZvcm1hdCBy
  >> "!B64TMP!" echo YW5rZWQgZGV2ZWxvcGVyLWluZGV4IHJlc3VsdHMgKG1pcnJvcnMgdGhlIE1DUCBmb3JtYXR0ZXIp
  >> "!B64TMP!" echo LiIiIgogICAgaWYgbm90IHJlc3VsdHM6CiAgICAgICAgcmV0dXJuICIobm8gcmVzdWx0cykiCiAg
  >> "!B64TMP!" echo ICBibG9ja3MgPSBbXQogICAgZm9yIHIgaW4gcmVzdWx0czoKICAgICAgICBpZiBub3QgaXNpbnN0
  >> "!B64TMP!" echo YW5jZShyLCBkaWN0KToKICAgICAgICAgICAgYmxvY2tzLmFwcGVuZChzdHIocikpCiAgICAgICAg
  >> "!B64TMP!" echo ICAgIGNvbnRpbnVlCiAgICAgICAgcmlkID0gci5nZXQoImlkIikgb3IgIj8iCiAgICAgICAga2lu
  >> "!B64TMP!" echo ZCA9IHN0cihyaWQpLnNwbGl0KCI6IiwgMSlbMF0KICAgICAgICBsaW5lcyA9IFsiIyMgW3t9XXt9
  >> "!B64TMP!" echo IHt9Ii5mb3JtYXQocmlkLCBmIiAoe2tpbmR9KSIgaWYga2luZCBlbHNlICIiLAogICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICByLmdldCgidGl0bGUiKSBvciAiKHVudGl0bGVk
  >> "!B64TMP!" echo KSIpXQogICAgICAgIGlmIHIuZ2V0KCJ1cmwiKToKICAgICAgICAgICAgbGluZXMuYXBwZW5kKHJb
  >> "!B64TMP!" echo InVybCJdKQogICAgICAgIHBhc3NhZ2VzID0gci5nZXQoInBhc3NhZ2VzIikKICAgICAgICBib2R5
  >> "!B64TMP!" echo ID0gIiIKICAgICAgICBpZiBpc2luc3RhbmNlKHBhc3NhZ2VzLCBsaXN0KToKICAgICAgICAgICAg
  >> "!B64TMP!" echo Ym9keSA9ICJcbi0tLVxuIi5qb2luKChwLmdldCgidGV4dCIpIG9yICIiKQogICAgICAgICAgICAg
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgaWYgaXNpbnN0YW5jZShwLCBkaWN0KSBlbHNlIHN0cihwKQog
  >> "!B64TMP!" echo ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZm9yIHAgaW4gcGFzc2FnZXMpLnN0cmlw
  >> "!B64TMP!" echo KCkKICAgICAgICBsaW5lcy5hcHBlbmQoYm9keVs6TUFYX1BBU1NBR0VfQ0hBUlNdIGlmIGJvZHkg
  >> "!B64TMP!" echo ZWxzZSAiKG5vIGNvbnRlbnQpIikKICAgICAgICBibG9ja3MuYXBwZW5kKCJcbiIuam9pbihsaW5l
  >> "!B64TMP!" echo cykpCiAgICByZXR1cm4gIlxuXG4iLmpvaW4oYmxvY2tzKQoKCmRlZiBtYWluKCkgLT4gaW50Ogog
  >> "!B64TMP!" echo ICAgYXJncyA9IFthIGZvciBhIGluIHN5cy5hcmd2WzE6XSBpZiBhICE9ICItLWpzb24iIGFuZCBh
  >> "!B64TMP!" echo ICE9ICItLXNraWxscy1vbmx5Il0KICAgIGFzX2pzb24gPSAiLS1qc29uIiBpbiBzeXMuYXJndlsx
  >> "!B64TMP!" echo Ol0KICAgIHNraWxsc19vbmx5ID0gIi0tc2tpbGxzLW9ubHkiIGluIHN5cy5hcmd2WzE6XQogICAg
  >> "!B64TMP!" echo cXVlcnkgPSAiICIuam9pbihhcmdzKS5zdHJpcCgpCiAgICBpZiBub3QgcXVlcnk6CiAgICAgICAg
  >> "!B64TMP!" echo cHJpbnQoJ3VzYWdlOiB3ZWJfZGV2ZWxvcGVyX3NlYXJjaC5weSAiPHF1ZXJ5PiIgWy0tc2tpbGxz
  >> "!B64TMP!" echo LW9ubHldIFstLWpzb25dJywKICAgICAgICAgICAgICBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAg
  >> "!B64TMP!" echo cmV0dXJuIDIKCiAgICBib2R5ID0geyJxdWVyeSI6IHF1ZXJ5fQogICAgaWYgc2tpbGxzX29ubHk6
  >> "!B64TMP!" echo CiAgICAgICAgYm9keVsic2tpbGxzIl0gPSAib25seSIKCiAgICB0cnk6CiAgICAgICAgZGF0YSA9
  >> "!B64TMP!" echo IGZjLmNhbGwoIi92MS9kZXZlbG9wZXIvc2VhcmNoIiwgbWV0aG9kPSJQT1NUIiwgYm9keT1ib2R5
  >> "!B64TMP!" echo KQogICAgZXhjZXB0IGZjLkZjRXJyb3IgYXMgZToKICAgICAgICBwcmludChmIkRFVkVMT1BFUiBT
  >> "!B64TMP!" echo RUFSQ0ggRkFJTEVEOiB7ZX0iLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgaWYgZS5oaW50Ogog
  >> "!B64TMP!" echo ICAgICAgICAgICBwcmludChlLmhpbnQsIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICByZXR1cm4g
  >> "!B64TMP!" echo MQoKICAgIGlmIGFzX2pzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhkYXRhKSkKICAgICAg
  >> "!B64TMP!" echo ICByZXR1cm4gMAogICAgcmVzdWx0cyA9IGRhdGEuZ2V0KCJyZXN1bHRzIikKICAgIGlmIHJlc3Vs
  >> "!B64TMP!" echo dHMgaXMgTm9uZToKICAgICAgICBwYXlsb2FkID0gZGF0YS5nZXQoImRhdGEiKSBpZiBpc2luc3Rh
  >> "!B64TMP!" echo bmNlKGRhdGEuZ2V0KCJkYXRhIiksIGRpY3QpIFwKICAgICAgICAgICAgZWxzZSBkYXRhCiAgICAg
  >> "!B64TMP!" echo ICAgcmVzdWx0cyA9IHBheWxvYWQuZ2V0KCJyZXN1bHRzIikgb3IgcGF5bG9hZC5nZXQoImRldmVs
  >> "!B64TMP!" echo b3BlciIpCiAgICBpZiBub3QgaXNpbnN0YW5jZShyZXN1bHRzLCBsaXN0KToKICAgICAgICByZXN1
  >> "!B64TMP!" echo bHRzID0gW10KICAgIHByaW50KGZtdF9kZXZlbG9wZXIocmVzdWx0cykpCiAgICByZXR1cm4gMAoK
  >> "!B64TMP!" echo CmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBzeXMuZXhpdChtYWluKCkpCg==
  set "LS_B64_IN=!B64TMP!"
  set "LS_B64_OUT=!TARGET!\local-web-search\scripts\web_developer_search.py"
  call :decode_b64
  if exist "!B64TMP!" del /Q "!B64TMP!" >nul 2>&1
)
if exist "!SRC!\install-local-search.bat" copy /Y "!SRC!\install-local-search.bat" "!TARGET!\install-local-search.bat" >nul 2>&1
if exist "!SRC!\install-local-search.sh"  copy /Y "!SRC!\install-local-search.sh"  "!TARGET!\install-local-search.sh"  >nul 2>&1
REM Always also drop the *current* installer (this script) into target, even if
REM the source copy above was skipped (e.g. user ran a renamed copy of the bat).
copy /Y "%~f0" "!TARGET!\install-local-search.bat" >nul 2>&1

echo Generating secure credentials...
call :genkey SECRET
call :genkey BULL
call :genkey PGPASS
call :genkey RABPASS
call :genkey BLESSTOKEN

echo Writing .env ...
> "!TARGET!\.env" echo # Local Search configuration - generated by install-local-search.bat
>> "!TARGET!\.env" echo # Edit ports/LLM here, then run Update.bat to apply.
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- Host ports ----
>> "!TARGET!\.env" echo SEARXNG_PORT=!SEARXNG_PORT!
>> "!TARGET!\.env" echo FIRECRAWL_PORT=!FIRECRAWL_PORT!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- SearXNG instance secret ----
>> "!TARGET!\.env" echo SEARXNG_SECRET=!SECRET!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- Firecrawl internal credentials ----
>> "!TARGET!\.env" echo BULL_AUTH_KEY=!BULL!
>> "!TARGET!\.env" echo POSTGRES_DB=firecrawl
>> "!TARGET!\.env" echo POSTGRES_USER=firecrawl
>> "!TARGET!\.env" echo POSTGRES_PASSWORD=!PGPASS!
>> "!TARGET!\.env" echo RABBITMQ_USER=firecrawl
>> "!TARGET!\.env" echo RABBITMQ_PASSWORD=!RABPASS!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- Browser rendering engine for Firecrawl ^(installer Step 4^) ----
>> "!TARGET!\.env" echo COMPOSE_PROFILES=!BROWSER_ENGINE!
>> "!TARGET!\.env" echo PLAYWRIGHT_MICROSERVICE_URL=!PW_URL!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo # ---- Browserless token ^(only used if COMPOSE_PROFILES=browserless above^) ----
>> "!TARGET!\.env" echo BROWSERLESS_TOKEN=!BLESSTOKEN!
>> "!TARGET!\.env" echo.
>> "!TARGET!\.env" echo LOGGING_LEVEL=info
if defined OPENAI_BASE_URL (
  >> "!TARGET!\.env" echo.
  >> "!TARGET!\.env" echo # ---- LLM for Firecrawl AI features ----
  >> "!TARGET!\.env" echo OPENAI_BASE_URL=!OPENAI_BASE_URL!
  >> "!TARGET!\.env" echo OPENAI_API_KEY=!OPENAI_API_KEY!
  if defined MODEL_NAME >> "!TARGET!\.env" echo MODEL_NAME=!MODEL_NAME!
)
if defined FC_API_KEY (
  >> "!TARGET!\.env" echo.
  >> "!TARGET!\.env" echo # ---- Firecrawl account ^(cloud API^) for account-only tools ----
  >> "!TARGET!\.env" echo FIRECRAWL_API_URL=!FC_API_URL!
  >> "!TARGET!\.env" echo FIRECRAWL_API_KEY=!FC_API_KEY!
)

echo Injecting SearXNG secret into settings.yml ...
powershell -NoProfile -Command "(Get-Content -Raw '!TARGET!\config\searxng\settings.yml') -replace '__SEARXNG_SECRET_PLACEHOLDER__', '!SECRET!' | Set-Content -NoNewline '!TARGET!\config\searxng\settings.yml'"

if defined FC_API_KEY goto skill_full
echo Installing the core-only local-web-search skill (no Firecrawl account)...
if exist "!TARGET!\local-web-search\scripts\web_agent.py" del /Q "!TARGET!\local-web-search\scripts\web_agent.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_agent_status.py" del /Q "!TARGET!\local-web-search\scripts\web_agent_status.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_interact.py" del /Q "!TARGET!\local-web-search\scripts\web_interact.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_interact_stop.py" del /Q "!TARGET!\local-web-search\scripts\web_interact_stop.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_parse.py" del /Q "!TARGET!\local-web-search\scripts\web_parse.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_create.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_create.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_list.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_list.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_get.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_get.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_update.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_update.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_delete.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_delete.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_run.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_run.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_checks.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_checks.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_monitor_check.py" del /Q "!TARGET!\local-web-search\scripts\web_monitor_check.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_research_search.py" del /Q "!TARGET!\local-web-search\scripts\web_research_search.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_research_inspect.py" del /Q "!TARGET!\local-web-search\scripts\web_research_inspect.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_research_related.py" del /Q "!TARGET!\local-web-search\scripts\web_research_related.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_research_read.py" del /Q "!TARGET!\local-web-search\scripts\web_research_read.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_github_search.py" del /Q "!TARGET!\local-web-search\scripts\web_github_search.py" >nul 2>&1
if exist "!TARGET!\local-web-search\scripts\web_developer_search.py" del /Q "!TARGET!\local-web-search\scripts\web_developer_search.py" >nul 2>&1
if exist "!TARGET!\local-web-search\SKILL-core.md" copy /Y "!TARGET!\local-web-search\SKILL-core.md" "!TARGET!\local-web-search\SKILL.md" >nul
:skill_full
REM SKILL-core.md is a build-time variant - never part of an installed skill.
if exist "!TARGET!\local-web-search\SKILL-core.md" del /Q "!TARGET!\local-web-search\SKILL-core.md" >nul 2>&1
REM LLM tools and the SKILL-llm.md section are kept only when an LLM is connected.
if defined OPENAI_BASE_URL goto llm_skill_keep
echo Skipping LLM extraction in the skill (no LLM connected)...
if exist "!TARGET!\local-web-search\scripts\web_extract.py" del /Q "!TARGET!\local-web-search\scripts\web_extract.py" >nul 2>&1
goto llm_skill_done
:llm_skill_keep
if exist "!TARGET!\local-web-search\SKILL-llm.md" type "!TARGET!\local-web-search\SKILL-llm.md" >> "!TARGET!\local-web-search\SKILL.md"
:llm_skill_done
if exist "!TARGET!\local-web-search\SKILL-llm.md" del /Q "!TARGET!\local-web-search\SKILL-llm.md" >nul 2>&1

echo Installing the local-web-search agent skill...
set "SKILL_DIR=%USERPROFILE%\.agents\skills\local-web-search"
if exist "!SKILL_DIR!" rd /s /q "!SKILL_DIR!"
if not exist "%USERPROFILE%\.agents\skills" mkdir "%USERPROFILE%\.agents\skills"
xcopy /E /I /Y /Q "!TARGET!\local-web-search" "!SKILL_DIR!" >nul
if errorlevel 1 (
  echo   [WARNING] Could not copy the local-web-search skill to !SKILL_DIR!.
) else (
  > "!TARGET!\local-web-search\install-dir.txt" echo !TARGET!
  > "!SKILL_DIR!\install-dir.txt" echo !TARGET!
  echo   Agent skill installed: !SKILL_DIR!
)

REM How long to wait for a just-launched Docker engine to come online (seconds).
set "DD_TIMEOUT=300"
if defined LOCAL_SEARCH_DOCKER_TIMEOUT set "DD_TIMEOUT=!LOCAL_SEARCH_DOCKER_TIMEOUT!"
if not defined DD_LAUNCHED goto docker_engine_ready
echo Waiting for the Docker engine to come online - up to !DD_TIMEOUT! seconds...
set /a DD_WAIT=0
:docker_wait
timeout /t 5 /nobreak >nul 2>&1
if errorlevel 1 ping -n 6 127.0.0.1 >nul 2>&1
set /a DD_WAIT+=5
docker info >nul 2>&1
if not errorlevel 1 goto docker_engine_ready
if !DD_WAIT! geq !DD_TIMEOUT! (
  echo [ERROR] The Docker engine did not come online within !DD_TIMEOUT! seconds.
  echo   Check Docker Desktop for errors, wait until it says "running",
  echo   then re-run this installer.
  pause & exit /b 1
)
set /a "DD_MOD=DD_WAIT %% 15"
if !DD_MOD! equ 0 echo     ... still waiting !DD_WAIT!s
goto docker_wait
:docker_engine_ready
if defined DD_LAUNCHED echo [OK] Docker engine is online after !DD_WAIT!s.

echo.
echo Pulling Docker images (first run downloads ~3-4 GB, please be patient)...
pushd "!TARGET!"
docker compose pull
if !errorlevel! neq 0 ( echo   [WARNING] docker compose pull reported errors. Trying to start anyway... )
echo Starting services...
docker compose up -d
set "UP_RC=!errorlevel!"
popd
if !UP_RC! neq 0 (
  echo.
  echo [ERROR] docker compose up failed. See messages above.
  echo   Common fixes:
  echo     - Make sure Docker Desktop is running.
  echo     - Make sure ports !SEARXNG_PORT! and !FIRECRAWL_PORT! are not in use.
  echo     - Re-run this installer or run Update.bat after fixing.
  echo.
  pause & exit /b 1
)

echo.
echo ============================================================
echo   Installation complete!
echo.
echo   SearXNG  (search + JSON API):  http://localhost:!SEARXNG_PORT!
echo   Firecrawl (scrape/crawl API): http://localhost:!FIRECRAWL_PORT!
echo   local-web-search skill:              %USERPROFILE%\.agents\skills\local-web-search
echo.
echo   If your agent was already running, restart it so it picks up
echo   the new skill.
echo.
echo   Manage the stack with the .bat files in:
echo     !TARGET!
echo       Run.bat   Stop.bat   Update.bat   Uninstall.bat
echo.
echo   See README.md for how to connect this to your AI models
echo   (local-web-search skill, LM Studio, MCP server, direct prompting, etc.).
echo ============================================================
echo.
pause
exit /b 0

REM ===========================================================================
REM  Subroutines
REM ===========================================================================

:llm_intro
echo   Lets Firecrawl do AI extraction ^(/v1/extract^) and summaries.
echo   Recommended: LM Studio  -^>  http://localhost:1234/v1
exit /b 0

:ask_llm
REM  The Firecrawl container reaches a host-side server through host.docker.internal.
set "LLM_URL="
set /p LLM_URL="    Base URL Endpoint [Enter = http://localhost:1234/v1]: "
if "!LLM_URL!"=="" set "LLM_URL=http://localhost:1234/v1"
set "LLM_KEY="
set /p LLM_KEY="    API Key [Enter to skip]: "
set "LLM_MODEL="
set /p LLM_MODEL="    Model name [Enter to skip]: "
set "OPENAI_BASE_URL=!LLM_URL!"
set "OPENAI_BASE_URL=!OPENAI_BASE_URL:http://localhost=http://host.docker.internal!"
set "OPENAI_BASE_URL=!OPENAI_BASE_URL:http://127.0.0.1=http://host.docker.internal!"
set "OPENAI_API_KEY=!LLM_KEY!"
if "!OPENAI_API_KEY!"=="" set "OPENAI_API_KEY=placeholder"
set "MODEL_NAME="
if not "!LLM_MODEL!"=="" set "MODEL_NAME=!LLM_MODEL!"
echo     ^(Container will reach it at: !OPENAI_BASE_URL!^)
exit /b 0

:validate_port
echo %~1| findstr /r /c:"^[0-9][0-9]*$" >nul
if errorlevel 1 exit /b 1
if %~1 lss 1 exit /b 1
if %~1 gtr 65535 exit /b 1
exit /b 0

:genkey
set "KFILE=%TEMP%\local_search_key.tmp"
powershell -NoProfile -Command "$rng=[Security.Cryptography.RandomNumberGenerator]::Create(); $r=New-Object byte[] 32; $rng.GetBytes($r); -join ($r | ForEach-Object { $_.ToString('x2') })" > "%KFILE%"
set /p "%~1=" < "%KFILE%"
del "%KFILE%" >nul 2>&1
exit /b 0

:decode_b64
REM  %1 = path to a .b64 text file, %2 = output binary path (may not exist yet)
REM  Pass paths via PS variables to survive spaces / quotes in TARGET.
powershell -NoProfile -Command "$in=$env:LS_B64_IN; $out=$env:LS_B64_OUT; [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String(((Get-Content -Raw $in) -replace '\s','')))"
exit /b 0
EOF_INSTALL_LOCAL_SEARCH_BAT
fi
[ -f "$SRC/install-local-search.sh" ] && cp "$SRC/install-local-search.sh" "$TARGET/install-local-search.sh"
[ -f "$SRC/install-local-search.bat" ] && cp "$SRC/install-local-search.bat" "$TARGET/install-local-search.bat"
# Always also drop the *current* installer (this script) into target, even
# if it was renamed (the check above looks for the canonical name).
cp -f "$0" "$TARGET/install-local-search.sh" 2>/dev/null || true
chmod +x "$TARGET"/*.sh 2>/dev/null || true
# The container reads this folder as a different uid (rootless Podman, SELinux):
# make sure it is world-readable even under a restrictive umask.
chmod 755 "$TARGET/config" "$TARGET/config/searxng" 2>/dev/null || true
chmod 644 "$TARGET/config/searxng/settings.yml" 2>/dev/null || true

for f in "$TARGET"/*.bat; do
  [ -f "$f" ] || continue
  if command -v awk >/dev/null 2>&1; then
    awk '{sub(/\r$/,""); printf "%s\r\n", $0}' "$f" > "$f.crlf" 2>/dev/null && mv "$f.crlf" "$f" || rm -f "$f.crlf"
  fi
done

if [ "$ENGINE_LAUNCHED" = "1" ]; then
  say "Waiting for the $ENGINE_NAME engine to come online - up to ${DOCKER_WAIT_TIMEOUT}s..."
  DD_WAIT=0
  while ! ls_engine_running; do
    sleep 5
    DD_WAIT=$((DD_WAIT + 5))
    if [ "$DD_WAIT" -ge "$DOCKER_WAIT_TIMEOUT" ]; then
      err "The $ENGINE_NAME engine did not come online within ${DOCKER_WAIT_TIMEOUT}s."
      ls_engine_hint
      say "  then start it and re-run this installer."
      exit 1
    fi
    if [ $((DD_WAIT % 15)) -eq 0 ]; then say "  ... still waiting, ${DD_WAIT}s elapsed"; fi
  done
  ok "$ENGINE_NAME engine is online after ${DD_WAIT}s."
fi

ls_platform_env
if [ -n "$LS_MOUNT_OPTS" ]; then say "  SELinux detected - the SearXNG config folder is mounted with the 'z' label."; fi
if [ "$LS_FORCE_OWNERSHIP" = "false" ]; then say "  Rootless Podman detected - SearXNG will not re-own the config folder."; fi

say "Generating secure credentials..."
genkey() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
  else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}
SECRET="$(genkey)"; BULL="$(genkey)"; PGPASS="$(genkey)"; RABPASS="$(genkey)"; BLESSTOKEN="$(genkey)"

say "Writing .env ..."
{
  echo "# Local Search configuration - generated by install-local-search.sh"
  echo "# Edit ports/LLM here, then run update.sh to apply."
  echo
  echo "# ---- Host ports ----"
  echo "SEARXNG_PORT=$SEARXNG_PORT"
  echo "FIRECRAWL_PORT=$FIRECRAWL_PORT"
  echo
  echo "# ---- SearXNG instance secret ----"
  echo "SEARXNG_SECRET=$SECRET"
  echo
  echo "# ---- Container engine: podman or docker. The installer records the one it used,"
  echo "# so run.sh / update.sh keep using it. Edit to switch (then run ./update.sh). ----"
  echo "LOCAL_SEARCH_ENGINE=$ENGINE"
  echo
  echo "# ---- SearXNG config-folder mount (decided by the installer, see docker-compose.yml) ----"
  echo "#   SEARXNG_MOUNT_OPTS=,z          SELinux hosts (Fedora/RHEL): lets the container read the folder"
  echo "#   SEARXNG_FORCE_OWNERSHIP=false  rootless Podman: keeps the folder owned by you"
  echo "SEARXNG_MOUNT_OPTS=$LS_MOUNT_OPTS"
  echo "SEARXNG_FORCE_OWNERSHIP=$LS_FORCE_OWNERSHIP"
  echo
  echo "# ---- Firecrawl internal credentials ----"
  echo "BULL_AUTH_KEY=$BULL"
  echo "POSTGRES_DB=firecrawl"
  echo "POSTGRES_USER=firecrawl"
  echo "POSTGRES_PASSWORD=$PGPASS"
  echo "RABBITMQ_USER=firecrawl"
  echo "RABBITMQ_PASSWORD=$RABPASS"
  echo
  echo "# ---- Browser rendering engine for Firecrawl (installer Step 4) ----"
  echo "COMPOSE_PROFILES=$BROWSER_ENGINE"
  echo "PLAYWRIGHT_MICROSERVICE_URL=$PW_URL"
  echo
  echo "# ---- Browserless token (only used if COMPOSE_PROFILES=browserless above) ----"
  echo "BROWSERLESS_TOKEN=$BLESSTOKEN"
  echo
  echo "LOGGING_LEVEL=info"
  if [ -n "$OPENAI_BASE_URL" ]; then
    echo
    echo "# ---- LLM for Firecrawl AI features ----"
    echo "OPENAI_BASE_URL=$OPENAI_BASE_URL"
    echo "OPENAI_API_KEY=$OPENAI_API_KEY"
    [ -n "$MODEL_NAME" ] && echo "MODEL_NAME=$MODEL_NAME"
  fi
  if [ -n "$FC_API_KEY" ]; then
    echo
    echo "# ---- Firecrawl account (cloud API) for account-only tools ----"
    echo "FIRECRAWL_API_URL=$FC_API_URL"
    echo "FIRECRAWL_API_KEY=$FC_API_KEY"
  fi
} > "$TARGET/.env"

say "Injecting SearXNG secret into settings.yml ..."
SFILE="$TARGET/config/searxng/settings.yml"
sed "s/__SEARXNG_SECRET_PLACEHOLDER__/$SECRET/" "$SFILE" > "$SFILE.tmp" && mv "$SFILE.tmp" "$SFILE"

if [ -z "$FC_API_KEY" ]; then
  say "Installing the core-only local-web-search skill (no Firecrawl account)..."
  rm -f "$TARGET/local-web-search/scripts/web_agent.py"
  rm -f "$TARGET/local-web-search/scripts/web_agent_status.py"
  rm -f "$TARGET/local-web-search/scripts/web_interact.py"
  rm -f "$TARGET/local-web-search/scripts/web_interact_stop.py"
  rm -f "$TARGET/local-web-search/scripts/web_parse.py"
  rm -f "$TARGET/local-web-search/scripts/web_monitor_create.py"
  rm -f "$TARGET/local-web-search/scripts/web_monitor_list.py"
  rm -f "$TARGET/local-web-search/scripts/web_monitor_get.py"
  rm -f "$TARGET/local-web-search/scripts/web_monitor_update.py"
  rm -f "$TARGET/local-web-search/scripts/web_monitor_delete.py"
  rm -f "$TARGET/local-web-search/scripts/web_monitor_run.py"
  rm -f "$TARGET/local-web-search/scripts/web_monitor_checks.py"
  rm -f "$TARGET/local-web-search/scripts/web_monitor_check.py"
  rm -f "$TARGET/local-web-search/scripts/web_research_search.py"
  rm -f "$TARGET/local-web-search/scripts/web_research_inspect.py"
  rm -f "$TARGET/local-web-search/scripts/web_research_related.py"
  rm -f "$TARGET/local-web-search/scripts/web_research_read.py"
  rm -f "$TARGET/local-web-search/scripts/web_github_search.py"
  rm -f "$TARGET/local-web-search/scripts/web_developer_search.py"
  if [ -f "$TARGET/local-web-search/SKILL-core.md" ]; then cp -f "$TARGET/local-web-search/SKILL-core.md" "$TARGET/local-web-search/SKILL.md"; fi
fi
# SKILL-core.md is a build-time variant - never part of an installed skill.
rm -f "$TARGET/local-web-search/SKILL-core.md"
# LLM tools and the SKILL-llm.md section are kept only when an LLM is connected.
if [ -n "$OPENAI_BASE_URL" ]; then
  if [ -f "$TARGET/local-web-search/SKILL-llm.md" ]; then cat "$TARGET/local-web-search/SKILL-llm.md" >> "$TARGET/local-web-search/SKILL.md"; fi
else
  say "Skipping LLM extraction in the skill (no LLM connected)..."
  rm -f "$TARGET/local-web-search/scripts/web_extract.py"
fi
rm -f "$TARGET/local-web-search/SKILL-llm.md"

say "Installing the local-web-search agent skill..."
SKILL_DIR="$HOME/.agents/skills/local-web-search"
rm -rf "$SKILL_DIR"
mkdir -p "$HOME/.agents/skills"
if cp -r "$TARGET/local-web-search" "$SKILL_DIR"; then
  printf '%s\n' "$TARGET" > "$TARGET/local-web-search/install-dir.txt"
  printf '%s\n' "$TARGET" > "$SKILL_DIR/install-dir.txt"
  say "  Agent skill installed: $SKILL_DIR"
else
  say "  ${YELLOW}[WARNING]${RESET} could not copy the local-web-search skill to $SKILL_DIR"
fi

echo
# docker-compose behind "podman compose" needs Podman's API socket.
if ! ls_ensure_podman_socket; then
  say "${YELLOW}[WARNING]${RESET} Podman's API socket is not active. If compose fails below, run:"
  say "    systemctl --user enable --now podman.socket"
fi
say "Pulling container images with $ENGINE_NAME (first run downloads ~3-4 GB, please be patient)..."
cd "$TARGET"
$DC pull || say "${YELLOW}[WARNING]${RESET} some images failed to pull; trying to start anyway."
say "Starting services..."
if ! $DC up -d; then
  err "$DC up failed. See messages above."
  say "  Common fixes:"
  if [ "$ENGINE" = "podman" ]; then
    say "    - Cannot connect to the Docker daemon / podman.sock?  systemctl --user enable --now podman.socket"
    say "    - Run 'podman info' to check that Podman itself works."
    say "    - A Python traceback from podman-compose? Update it (sudo dnf upgrade podman-compose)"
    say "      or install Compose v2 instead:  sudo dnf install docker-compose"
  else
    say "    - Make sure Docker is running (and your user is in the 'docker' group on Linux)."
  fi
  say "    - Make sure ports $SEARXNG_PORT and $FIRECRAWL_PORT are not in use."
  say "    - Re-run this installer or run update.sh after fixing."
  exit 1
fi

echo
if ! ls_verify_searxng "$SEARXNG_PORT"; then
  echo
  say "${RED}============================================================${RESET}"
  say "${RED}  Installed, but SearXNG is not answering.${RESET}"
  say "  The files, the skill and the containers are in place; fix the problem"
  say "  shown above, then run ./run.sh in:  $TARGET"
  say "${RED}============================================================${RESET}"
  exit 1
fi
echo
if ! ls_fix_container_proxy "$SEARXNG_PORT"; then
  echo
  say "${RED}============================================================${RESET}"
  say "${RED}  Installed, but the containers inherit a proxy setting that cannot work.${RESET}"
  say "  Searches would come back empty. Details above; after fixing, run ./run.sh in:"
  say "    $TARGET"
  say "${RED}============================================================${RESET}"
  exit 1
fi

echo
say "${GREEN}============================================================${RESET}"
say "${GREEN}  Installation complete!${RESET}"
echo
say "  SearXNG  (search + JSON API):  http://localhost:$SEARXNG_PORT"
say "  Firecrawl (scrape/crawl API): http://localhost:$FIRECRAWL_PORT"
say "  Container tool:                $ENGINE_NAME ($DC)"
say "  local-web-search skill:              $HOME/.agents/skills/local-web-search"
echo
say "  If your agent was already running, restart it so it picks up"
say "  the new skill."
echo
say "  Manage the stack with the scripts in:"
say "    $TARGET"
say "      ./run.sh   ./stop.sh   ./update.sh   ./uninstall.sh"
echo
say "  See README.md for how to connect this to your AI models"
say "  (local-web-search skill, LM Studio, MCP server, direct prompting, etc.)."
say "${GREEN}============================================================${RESET}"
