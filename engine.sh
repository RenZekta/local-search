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
