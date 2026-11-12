#!/bin/bash
# =================================================================
#   OpenConnect Master Manager - v8.0.0
#   - New: systemd management (ocm.service). openconnect now runs in the foreground and is reconnected
#     automatically according to why it exited (server session expiry / network error / auth failure are handled separately); netns and proxies stay up while reconnecting;
#     closing SSH no longer affects the VPN.
#   - New: built-in long-term diagnostic log (ocm-watch.service): periodic samples, events, incident snapshots, reports.
#   - New: ⚙️ Settings menu + /etc/oc-master/settings.conf - every tunable has a description and choices;
#     a summary is shown before starting: start directly / change settings first / override for this run only.
#   - New: command-line interface (ocm -h): start / stop / restart / status / log / heal / config / accounts.
#   - Changed: netns mode no longer enables host-wide IPv6 forwarding by default (can be enabled in settings); the VPN password is no longer exported
#     into child process environments; the account list and status area no longer show passwords in clear text.
#   - Kept: Default global / ocproxy / Netns modes; SSH protection routes; socat / iptables forwarding backends.
# =================================================================
set -euo pipefail

# --- Global Configuration ---
VERSION="8.0.0"
VR_TAG="OC-Master-v${VERSION}"
SCRIPT_PATH="$(readlink -f "$0")"
PID_FILE="/var/run/oc_manager.pid"
GOST_PID_FILE="/var/run/oc_gost.pid"
SOCAT_PID_FILE="/var/run/oc_socat.pid"
SOCAT_PID_FILE_V6="${SOCAT_PID_FILE}.v6"
STATE_FILE="/var/run/oc_manager.state"
# setup_netns turns the kernel forwarding switches on; the previous values are recorded here and cleanup_netns restores them
SYSCTL_STATE_FILE="/var/run/oc_manager.sysctl"
ACCOUNTS_FILE="/root/.vpn_accounts.env"
SHORTCUT_PATH="/usr/local/bin/ocm"
# Dependency marker: records only dependencies "installed by this script" (uninstall uses it to choose remove-by-default vs keep-by-default)
DEPS_STATE_DIR="/var/lib/oc-master"
DEPS_MARK_FILE="${DEPS_STATE_DIR}/installed-deps"

# --- v8: settings / runtime / logs ---
CONF_DIR="/etc/oc-master"
SETTINGS_FILE="${CONF_DIR}/settings.conf"
RUN_DIR="/run/oc-master"
RUN_PROFILE="${RUN_DIR}/run.conf"        # effective settings of the current start (600; no VPN password)
PHASE_FILE="${RUN_DIR}/phase"            # supervisor phase: starting/connecting/up/reconnecting/stopping/stopped/failed:<reason>
RESTART_REQ="${RUN_DIR}/restart-request" # watch process requests a soft reconnect
SESSION_LOG="${RUN_DIR}/oc-session.log"  # output of the current openconnect run (used to classify the exit reason)
LOG_DIR="/var/log/oc-master"
EVENTS="${LOG_DIR}/events.log"
SAMPLES="${LOG_DIR}/samples.log"
OCLOG="${LOG_DIR}/openconnect.log"
INC_DIR="${LOG_DIR}/incidents"
LAUNCH_DIR="${LOG_DIR}/launch"
WATCH_LIB="${DEPS_STATE_DIR}/watch"
SVC_MAIN="ocm.service"
SVC_WATCH="ocm-watch.service"
UNIT_DIR="/etc/systemd/system"
START_TIMEOUT=90                         # max time (seconds) ocm start waits for the tunnel to come up
OC_TUN_DEFAULT="ocmtun0"                 # tunnel interface name in Default global mode (in netns mode it lives in the namespace and is still tun0)

# --- Routing & Network Config ---
RT4_ID=100; RT4_NAME="vps_return4"
RT6_ID=101; RT6_NAME="vps_return6"
NETNS_NAME="ocm_vpn_space"
VETH_HOST="veth_ocm_h"
VETH_NS="veth_ocm_ns"
VETH_HOST_IP="192.168.200.1"
VETH_NS_IP="192.168.200.2"
VETH_SUBNET="192.168.200.0/24"

# --- Command Paths ---
IP_CMD="$(command -v ip || echo /sbin/ip)"
IPTABLES_CMD="$(command -v iptables || echo /sbin/iptables)"
CURL_CMD="$(command -v curl || echo /usr/bin/curl)"

# --- Styles & Logging ---
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_GREY='\033[90m'
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_CYAN='\033[36m'
# No color codes when not on a terminal (systemd / pipes), so log files stay clean
if [ ! -t 1 ]; then C_RESET=''; C_BOLD=''; C_GREY=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; fi
log()      { echo -e "${C_GREEN}✅ [$VR_TAG] $1${C_RESET}"; }
log_err()  { echo -e "${C_RED}❌ [$VR_TAG] $1${C_RESET}" >&2; }
log_info() { echo -e "${C_CYAN}ℹ️  [$VR_TAG] $1${C_RESET}"; }
log_warn() { echo -e "${C_YELLOW}⚠️  [$VR_TAG] $1${C_RESET}"; }
title()    { echo -e "${C_BOLD}$1${C_RESET}"; }
sep()      { echo -e "${C_GREY}--------------------------------------------------------${C_RESET}"; }
check_root(){ [ "$EUID" -eq 0 ] || { log_err "Please run as root"; exit 1; }; }

# Event log: one event per line, time taken with builtins only (on stop SIGTERM goes to the whole cgroup, so $(...) would race)
ev() {
  local _t _e
  printf -v _t '%(%Y-%m-%dT%H:%M:%S%z)T' -1; printf -v _e '%(%s)T' -1
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s e=%s %s\n' "$_t" "$_e" "$*" >> "$EVENTS" 2>/dev/null || true
  return 0
}
now_s() { printf '%(%s)T' -1; }
fmt_dur() { # seconds -> 1d02h03m / 1h02m03s / 2m03s / 5s
  local s=${1:-0} d h m; [[ "$s" =~ ^[0-9]+$ ]] || { echo "$s"; return; }
  d=$((s/86400)); h=$((s%86400/3600)); m=$((s%3600/60)); s=$((s%60))
  if [ $d -gt 0 ]; then printf '%dd%02dh%02dm' $d $h $m
  elif [ $h -gt 0 ]; then printf '%dh%02dm%02ds' $h $m $s
  elif [ $m -gt 0 ]; then printf '%dm%02ds' $m $s
  else printf '%ds' $s; fi
}
# Redaction: passwords/passphrases/cookies/session tokens are always replaced (openconnect HTTP exchanges may contain DSID etc.)
redact() {
  sed -E 's/((pass(word|wd)?|cookie|DSID|DSFirstAccess|DSLastAccess|DSSignInURL|token|secret|authorization|SOCKS_PASS)[[:space:]]*[:=][[:space:]]*)[^[:space:];&]+/\1<redacted>/Ig'
}

# --- ocm shortcut command ---
# A symlink rather than a copy: the script resolves its real path with readlink -f "$0", so
# calling it via /usr/local/bin/ocm behaves exactly the same (menu, ocm stop, _internal_* all work).
# Only links that "already point to this script" are taken over; a real file with the same name is never overwritten.
install_shortcut() {
  local quiet="${1:-}"
  local current=""
  if [ -L "$SHORTCUT_PATH" ]; then
    current="$(readlink -f "$SHORTCUT_PATH" 2>/dev/null || true)"
    if [ "$current" = "$SCRIPT_PATH" ]; then
      [ -n "$quiet" ] || log "Shortcut command is already in place: ${SHORTCUT_PATH}"
      return 0
    fi
    log_err "${SHORTCUT_PATH} is a symlink pointing elsewhere (${current:-unknown}), refusing to overwrite."
    return 1
  fi
  if [ -e "$SHORTCUT_PATH" ]; then
    log_err "${SHORTCUT_PATH} already exists and is not a symlink, refusing to overwrite."
    return 1
  fi
  # A symlink requires the target itself to be executable. The normal install flow already does chmod +x, but if the script was
  # started as `bash oc_master.sh`, the exec bit may still be missing, so add it here.
  [ -x "$SCRIPT_PATH" ] || chmod +x "$SCRIPT_PATH" 2>/dev/null || true
  if [ ! -x "$SCRIPT_PATH" ]; then
    log_err "The script is not executable, so the shortcut would not work: ${SCRIPT_PATH}"
    return 1
  fi
  ln -s "$SCRIPT_PATH" "$SHORTCUT_PATH" || { log_err "Failed to create shortcut command: ${SHORTCUT_PATH}"; return 1; }
  log "Shortcut command installed: ${SHORTCUT_PATH} -> ${SCRIPT_PATH}"
  log_info "From now on you can simply run: ocm   or   ocm stop"
}

remove_shortcut() {
  local current=""
  [ -L "$SHORTCUT_PATH" ] || return 0
  current="$(readlink -f "$SHORTCUT_PATH" 2>/dev/null || true)"
  [ "$current" = "$SCRIPT_PATH" ] && { rm -f "$SHORTCUT_PATH"; log "Removed shortcut command ${SHORTCUT_PATH}"; }
  return 0
}

# Make sure the shortcut exists whenever the script starts (it no longer takes a menu item). Left alone in these cases:
#   - the script itself lives in /tmp or another temp dir (just downloaded, or under test) -> no link to a temp file
#   - a real file with the same name, or a symlink pointing elsewhere -> may belong to another program, never overwritten
# Only a "dangling link" is taken over: that is debris left after this script was moved/deleted.
_ensure_shortcut() {
  local tgt=""
  case "$SCRIPT_PATH" in /tmp/*|/var/tmp/*) return 0 ;; esac
  if [ -L "$SHORTCUT_PATH" ]; then
    tgt="$(readlink -f "$SHORTCUT_PATH" 2>/dev/null || true)"
    [ -n "$tgt" ] && return 0
    rm -f "$SHORTCUT_PATH" 2>/dev/null || return 0
  elif [ -e "$SHORTCUT_PATH" ]; then
    return 0
  fi
  install_shortcut quiet >/dev/null 2>&1 || true
  return 0
}

# One-line summary for the main menu status area (plain text, the caller adds color)
_shortcut_state() {
  local tgt="" base=""
  if [ -L "$SHORTCUT_PATH" ]; then
    tgt="$(readlink -f "$SHORTCUT_PATH" 2>/dev/null || true)"
    if [ "$tgt" = "$SCRIPT_PATH" ]; then echo "ocm ✓"
    elif [ -n "$tgt" ]; then base="$(basename "$tgt")"; echo "ocm → ${base}"
    else echo "ocm dangling link"; fi
  elif [ -e "$SHORTCUT_PATH" ]; then
    echo "ocm not linked to this script"
  else
    echo "ocm not installed"
  fi
  return 0
}

# --- Dependency check ---
_mark_dep_installed() {
  local name="$1"
  mkdir -p "$DEPS_STATE_DIR" 2>/dev/null || return 0
  if ! grep -qxF "$name" "$DEPS_MARK_FILE" 2>/dev/null; then
    echo "$name" >> "$DEPS_MARK_FILE" 2>/dev/null || true
  fi
  return 0
}
# 0 = this dependency was installed by this script; non-0 = it was already there (or the marker file does not exist)
_dep_installed_by_us() { grep -qxF "$1" "$DEPS_MARK_FILE" 2>/dev/null; }

# Removable dependencies: marker name|command|purpose. iptables/iproute2 are system basics and not listed.
_DEPS_LIST=(
  "openconnect|openconnect|VPN client (needed by all three modes)"
  "ocproxy|ocproxy|ocproxy mode"
  "gost|gost|SOCKS5 server for Netns mode"
  "socat|socat|port forwarding for Netns mode (preferred, provides both IPv4/IPv6 entry points; without it menu 3 cannot start, use the kernel forwarding of menu 4 instead)"
)

# Menu 8: scan the current state first, then decide what to install
show_deps() {
  local entry name cmd desc state
  title "📦 Dependency status:"
  for entry in "${_DEPS_LIST[@]}"; do
    IFS='|' read -r name cmd desc <<< "$entry"
    if command -v "$cmd" &>/dev/null; then
      if _dep_installed_by_us "$name"; then
        state="${C_GREEN}✔ installed${C_RESET} ${C_GREY}(installed by this script, safe to remove on uninstall)${C_RESET}"
      else
        state="${C_GREEN}✔ installed${C_RESET} ${C_YELLOW}(installed by you, kept by default on uninstall)${C_RESET}"
      fi
    else
      state="${C_RED}✘ missing${C_RESET}"
    fi
    # Note the echo -e: the color variables hold a literal \033[...m, and printf %s does not interpret escapes
    printf '  %-12s ' "$name"
    echo -e "${desc}  ${state}"
  done
  sep
}
manage_deps() {
  show_deps
  local entry name cmd desc todo=() ans
  for entry in "${_DEPS_LIST[@]}"; do
    IFS='|' read -r name cmd desc <<< "$entry"
    command -v "$cmd" &>/dev/null || todo+=("$entry")
  done
  if [ ${#todo[@]} -eq 0 ]; then log "All dependencies are present, nothing to install."; return 0; fi
  log_warn "${#todo[@]} dependenc(ies) missing."
  read -rp "Install the missing dependencies now? [Y/n]: " ans || ans=""
  [[ "$ans" =~ ^[nN]$ ]] && { log_info "Installation skipped."; return 0; }
  for entry in "${todo[@]}"; do
    IFS='|' read -r name cmd desc <<< "$entry"
    if [ "$name" = "gost" ]; then
      _install_gost_now || true
    else
      _pkg_install "$name"
      if command -v "$cmd" &>/dev/null; then _mark_dep_installed "$name"; log "$name installed."
      else log_err "Failed to install $name, please install it manually."; fi
    fi
  done
  sep; show_deps
}

_pkg_install() {
  local pkg="$1"
  log_info "Installing $pkg..."
  if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -yq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -yq "$pkg" >/dev/null || true
  elif command -v yum &>/dev/null; then
    yum install -y "$pkg" >/dev/null || true
  elif command -v dnf &>/dev/null; then
    dnf install -y "$pkg" >/dev/null || true
  fi
}
ensure_pkg_openconnect() { command -v openconnect &>/dev/null || { _pkg_install openconnect; command -v openconnect &>/dev/null || { log_err "Failed to install openconnect"; exit 1; }; _mark_dep_installed openconnect; log "OpenConnect installed (marked as installed by this script)"; }; }
ensure_pkg_ocproxy()     { command -v ocproxy     &>/dev/null || { _pkg_install ocproxy; command -v ocproxy &>/dev/null || { log_err "Failed to install ocproxy"; exit 1; }; _mark_dep_installed ocproxy; log "ocproxy installed (marked as installed by this script)"; }; }
ensure_pkg_iptables()    { command -v iptables    &>/dev/null || { _pkg_install iptables; command -v iptables &>/dev/null || { log_err "Failed to install iptables"; exit 1; }; log "iptables is ready"; }; }
ensure_cmd_ss()          { command -v ss &>/dev/null || { _pkg_install iproute2 || _pkg_install iproute; log "iproute2 is ready"; }; }
_install_gost_now() { # only installs, does not ask (the caller asks, to avoid asking twice)
  log_info "Installing gost using the official script..."
  if ! command -v curl &>/dev/null; then _pkg_install curl; fi
  # Must not be written as `bash <(curl ...) --install || {...}`: a failure inside process substitution is not caught by `||` -
  # when curl fails on DNS/network/404, bash just reads empty input and exits 0, so that failure branch is dead code,
  # and the real failure only shows up at the command -v below (with a hint pointing at PATH instead of the network). Download first, then run.
  local _gi="/tmp/oc_gost_install.$$.sh"
  if ! "$CURL_CMD" -fsSL "https://github.com/go-gost/gost/raw/master/install.sh" -o "$_gi"; then
    log_err "Failed to download the gost installer (network/proxy/404). Check the network or install gost manually."
    rm -f "$_gi" 2>/dev/null || true
    return 1
  fi
  if ! bash "$_gi" --install; then
    log_err "The gost installer failed. Check its output or install gost manually."
    rm -f "$_gi" 2>/dev/null || true
    return 1
  fi
  rm -f "$_gi" 2>/dev/null || true
  if ! command -v gost &>/dev/null; then
    log_err "gost command not found after installation. Please check your PATH variable or the script output."
    return 1
  fi
  _mark_dep_installed gost
  log "gost has been successfully installed."
  return 0
}
ensure_cmd_gost() {
  command -v gost &>/dev/null && return 0
  log_warn "Netns mode requires 'gost' as a SOCKS5 server."
  local yn=""
  read -rp "Install gost now using the official script? [Y/n]: " yn || yn=""
  [[ "$yn" =~ ^[nN]$ ]] && { log_err "User cancelled installation. Netns mode cannot be started."; return 1; }
  _install_gost_now
}
ensure_cmd_socat() {
  command -v socat &>/dev/null && return 0
  log_warn "Netns mode prefers 'socat' for port forwarding (menu 3 needs it; install it, or pick menu 4 for the kernel path)."
  local yn=""
  read -rp "Install socat now? [Y/n]: " yn || yn=""
  [[ "$yn" =~ ^[nN]$ ]] && { log_info "Cancelled: menu 3 needs socat; use menu 4 for the kernel path."; return 1; }
  _pkg_install socat
  command -v socat &>/dev/null || { log_warn "socat installation failed: menu 3 cannot start, use menu 4 for the kernel path."; return 1; }
  _mark_dep_installed socat
  log "socat has been installed."
  return 0
}
check_atd() { if ! command -v at &>/dev/null || ! systemctl is-active --quiet atd; then log_warn "at/atd is missing or not running, attempting to install and start..."; _pkg_install at; systemctl enable --now atd 2>/dev/null || log_err "Failed to start atd automatically"; fi; }

# Same usage as `grep -q`, but safe at the end of a pipeline under `set -o pipefail`.
# Pitfall: in `cmd | grep -q PAT` grep exits on the first match, the rest of cmd's output hits SIGPIPE (exit code 141),
# and pipefail then marks the whole pipeline as failed - a match is treated as "no match".
# Measured: `ip netns exec NS ip link show | grep -q 'tun.*UP'` returned non-0 in 262/1500 (about 17%) of runs:
# so Netns mode occasionally logged "TUN ready" immediately followed by "start failed" (the tunnel was actually fine).
# `grep -c` must read all input before printing, so it never interrupts the upstream; the verdict is the same as -q.
_gq() { grep -c "$@" >/dev/null; }

# Wait for a process to exit, at most 10 seconds; SIGKILL only if it is still alive.
# Used in netns mode: killing openconnect and immediately running cleanup_netns tears down the
# veth->NAT path it logs out over, so openconnect just hangs on a TLS timeout (measured 80+ seconds),
# the previous session is not cleanly gone and the next connection fights with it.
_wait_pid_gone() {
  local pid="$1" i=0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  while [ "$i" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5; i=$((i + 1))
  done
  kill -9 "$pid" 2>/dev/null || true
}

# --- Public IP lookup ---
# With a single provider (formerly ip.p3terx.com), once it went down the whole status area just showed "lookup failed" -
# measured: ip.p3terx.com is completely unreachable (80/443 both Failed to connect, 0 of 10 attempts succeeded),
# so we now fall back through several providers in order, the first being the most reliable in tests.
_PUB_PROVIDERS4=("https://api.ipify.org" "https://ifconfig.me/ip" "https://ip.p3terx.com")
# IPv6 is usually unavailable, so fail fast: few candidates, short timeouts, so the status area does not hang for ten-plus seconds.
_PUB_PROVIDERS6=("https://api64.ipify.org" "https://ifconfig.me/ip")
# $1=-4/-6; $2=optional socks5h proxy. On success prints the address and returns 0; returns 1 if all fail.
_pub_ip() {
  local fam="$1" proxy="${2:-}" url out
  local list=("${_PUB_PROVIDERS4[@]}")
  local tmo=(-s -A "Mozilla/5.0" --connect-timeout 4 --max-time 8)
  if [ "$fam" = "-6" ]; then
    list=("${_PUB_PROVIDERS6[@]}")
    tmo=(-s -A "Mozilla/5.0" --connect-timeout 3 --max-time 5)
  fi
  [ -n "$proxy" ] && tmo=(-s -A "Mozilla/5.0" --connect-timeout 6 --max-time 12 -x "$proxy")
  for url in "${list[@]}"; do
    out=$("$CURL_CMD" "$fam" "${tmo[@]}" "$url" 2>/dev/null | head -n1 | tr -d '\r\n[:space:]')
    [ -n "$out" ] && { echo "$out"; return 0; }
  done
  return 1
}

# Decide whether the netns-mode VPN actually works - the criterion is "the real egress inside netns != the host's egress",
# not "is tun0 there" or "does ping work" (both give false positives, see _start_netns_logic).
# Returns 0 = works; 1 = definitely not working; 2 = cannot tell (even the host egress cannot be looked up, e.g. restricted network).
# The start flow and the guard task share this function so the two criteria never drift apart.
# The netns egress address found by the probe (lets callers print real information; the probe's return value is still tri-state)
_NS_PROBE_IP=""
_netns_vpn_probe() {
  local host_ip ns_ip
  _NS_PROBE_IP=""
  host_ip="$(_pub_ip -4 2>/dev/null || true)"
  [ -n "$host_ip" ] || return 2
  ns_ip="$("$IP_CMD" netns exec "${NETNS_NAME}" "$CURL_CMD" -4 -s --max-time 6 "${_PUB_PROVIDERS4[0]}" 2>/dev/null | head -n1 || true)"
  if [ -n "$ns_ip" ] && [ "$ns_ip" != "$host_ip" ]; then _NS_PROBE_IP="$ns_ip"; return 0; fi
  return 1
}

# --- IPv6 connectivity test ---
test_netns_ipv6() {
  local test_passed=0
  log_info "Testing IPv6 connectivity inside Netns..."
  if ! "$IP_CMD" netns list | _gq "${NETNS_NAME}"; then log_err "Netns ${NETNS_NAME} does not exist, cannot perform test."; return 1; fi
  
  # Test 1: check for an IPv6 address
  if "$IP_CMD" netns exec "${NETNS_NAME}" ip -6 addr show 2>/dev/null | _gq "inet6.*scope global"; then
    log "✓ Global IPv6 address exists in Netns"
    test_passed=$((test_passed + 1))
  else
    log_warn "✗ No global IPv6 address found in Netns"
  fi
  
  # Test 2: Ping IPv6 DNS
  if "$IP_CMD" netns exec "${NETNS_NAME}" ping -6 -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1; then
    log "✓ Can ping Google's IPv6 DNS from within Netns"
    test_passed=$((test_passed + 1))
  else
    log_warn "✗ Cannot ping IPv6 addresses from within Netns"
  fi
  
  # Test 3: HTTP IPv6 request
  if "$IP_CMD" netns exec "${NETNS_NAME}" curl -6 -s --connect-timeout 5 --max-time 10 https://ipv6.google.com >/dev/null 2>&1; then
    log "✓ Can access the internet via IPv6 from within Netns"
    test_passed=$((test_passed + 1))
  else
    log_warn "✗ Cannot access the internet via IPv6 from within Netns"
  fi
  
  if [ $test_passed -ge 2 ]; then
    log "IPv6 functionality test passed ($test_passed/3)"
    return 0
  else
    log_warn "IPv6 functionality test partially failed ($test_passed/3), but this will not affect IPv4 functionality"
    return 1
  fi
}

# --- Core network functions ---
check_rt_conflict() {
  local id="$1" name="$2"
  [ -d /etc/iproute2 ] || mkdir -p /etc/iproute2
  [ -f /etc/iproute2/rt_tables ] || touch /etc/iproute2/rt_tables
  if grep -qsE "^\s*$id\s" /etc/iproute2/rt_tables && ! grep -qsE "^\s*$id\s+$name\s*$" /etc/iproute2/rt_tables; then
    log_err "Routing table conflict: ID $id is already in use but the name is not $name"; exit 1
  fi
  grep -qxF "$id $name" /etc/iproute2/rt_tables || echo "$id $name" >> /etc/iproute2/rt_tables
}
is_vpn_running() { [ -f "$PID_FILE" ] || return 1; local pid; pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"; [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$PID_FILE"; return 1; }; ps -p "$pid" -o comm= 2>/dev/null | grep -q "^openconnect$"; }
_check_port_free() { local port="$1"; ensure_cmd_ss || true; if command -v ss &>/dev/null && ss -lntup 2>/dev/null | _gq ":${port} "; then return 1; fi; return 0; }

# --- SSH protection routes (used by Default mode) ---
setup_ssh_protect_routes() {
  local gw_dev="" gw4="" vps4="" default_ipv6_route="" vps6="" gw6_addr="" gw6_if="" onlink_flag=""
  gw_dev=$("$IP_CMD" route | awk '/^default/ {print $5; exit}')
  gw4=$("$IP_CMD" route | awk '/^default/ {print $3; exit}')
  vps4=$("$IP_CMD" -4 -o addr show dev "$gw_dev" | awk '{print $4}' | cut -d/ -f1 | head -n1)
  # All three values are required: if any fails to parse, the `ip route replace default via '' dev ''` and
  # `ip rule add from '' ...` below both fail; and since this function is called inside an if condition, set -e is
  # suppressed there - the failure does not abort, the script carries on "without SSH protection" and brings the global VPN up,
  # cutting exactly the SSH connection the user is working over. So fail right here and let the caller take the failure branch (stop_vpn + cancel the fallback job).
  [ -n "$gw_dev" ] && [ -n "$gw4" ] && [ -n "$vps4" ] || { log_err "Cannot parse default route / local address (dev='$gw_dev' via='$gw4' addr='$vps4'); aborting so the SSH connection survives"; return 1; }

  check_rt_conflict "$RT4_ID" "$RT4_NAME"
  log "Configuring IPv4 policy routing (for SSH protection)..."
  # This step must be checked: if the protection table has no default route but the from rule below is still added, traffic
  # from the local address is sent into an empty table and becomes unreachable (SSH drops at once). Better to refuse to start than to be "half configured".
  "$IP_CMD" route replace default via "$gw4" dev "$gw_dev" table "$RT4_ID" \
    || { log_err "Failed to write the IPv4 protection route (table $RT4_ID); aborting so the SSH connection survives"; return 1; }
  "$IP_CMD" rule del from "$vps4" table "$RT4_ID" priority 500 2>/dev/null || true
  "$IP_CMD" rule add from "$vps4" table "$RT4_ID" priority 500
  log "IPv4 OK (from $vps4)"

  default_ipv6_route=$("$IP_CMD" -6 route | awk '/^default/ && $0 !~ /tun/ {print; exit}' || true)
  vps6=$("$IP_CMD" -6 -o addr show dev "$gw_dev" scope global | awk '{print $4; exit}' | cut -d/ -f1 || true)
  # The default route may be multipath: the first line is only "default proto static metric N pref medium",
  # and gateway and device are on the following indented "nexthop via X dev Y" lines. Taking fixed columns $3/$5 yields
  # "static"/"1024", and `ip -6 route replace` fails with inet6 address is expected - but the script
  # would still add a rule pointing at the empty table 101, blackholing the host's outgoing IPv6 traffic (SSH over IPv6
  # drops), while printing "IPv6 OK" (reproducible on every host whose IPv6 default route is in multi-hop nexthop form).
  # So fields are now taken by the via/dev keywords (independent of column position) and validated before use; if not found, skip.
  local v6line="" v6_ok=""
  v6line=$("$IP_CMD" -6 route | awk '
    /^default/ { inblk=1; if ($0 !~ /tun/ && $0 ~ / via /) { print; exit } ; next }
    inblk && /^[[:space:]]/ { if ($0 !~ /tun/ && $0 ~ / via /) { print; exit } ; next }
    { inblk=0 }' || true)
  if [ -n "$v6line" ]; then
    gw6_addr=$(printf '%s\n' "$v6line" | awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}')
    gw6_if=$(printf '%s\n' "$v6line" | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    case "$v6line" in *" onlink "*|*" onlink") onlink_flag="onlink" ;; esac
  fi
  # Validation: the gateway must look like an IPv6 address (contains a colon), the device must really exist, and it must be the same
  # device as the IPv4 default route - the protection table's default route must leave via the NIC holding the local address, otherwise source address and egress device do not match.
  [ -n "$gw6_addr" ] && [ -n "$gw6_if" ] && [ "${gw6_addr#*:}" != "$gw6_addr" ] \
    && [ "$gw6_if" = "$gw_dev" ] \
    && "$IP_CMD" link show dev "$gw6_if" >/dev/null 2>&1 && v6_ok=1
  if [ -n "$default_ipv6_route" ] && [ -n "$vps6" ] && [ -n "$v6_ok" ]; then
    check_rt_conflict "$RT6_ID" "$RT6_NAME"
    log "Configuring IPv6 policy routing (for SSH protection)..."
    if "$IP_CMD" -6 route replace default via "$gw6_addr" dev "$gw6_if" $onlink_flag table "$RT6_ID"; then
      "$IP_CMD" -6 rule del from "$vps6" table "$RT6_ID" priority 500 2>/dev/null || true
      "$IP_CMD" -6 rule add from "$vps6" table "$RT6_ID" priority 500
      log "IPv6 OK (from $vps6)"
    else
      # Same as IPv4: if the protection table cannot be written, never add the rule (otherwise IPv6 traffic is sent to an empty table).
      log_warn "Failed to write the IPv6 protection route; skipping IPv6 protection (IPv4 protection is unaffected)"
    fi
  else
    if [ -n "$default_ipv6_route" ] && [ -n "$vps6" ]; then
      log_warn "IPv6 default route has no resolvable gateway (multipath/nexthop form?); skipping IPv6 protection"
    else
      log_info "No available IPv6 default route or address, skipping IPv6 setup"
    fi
    vps6="" # make sure vps6 is empty
  fi

  { echo "VPS4=${vps4:-}"; echo "VPS6=${vps6:-}"; } > "$STATE_FILE"
}

# --- Network Namespace management ---
setup_netns() {
  ensure_pkg_iptables
  log_info "Configuring Network Namespace: ${NETNS_NAME}..."
  
  "$IP_CMD" link del "${VETH_HOST}" 2>/dev/null || true
  "$IP_CMD" netns del "${NETNS_NAME}" 2>/dev/null || true
  
  "$IP_CMD" netns add "${NETNS_NAME}"
  
  log_info "Configuring DNS for Netns..."
  local netns_dir="/etc/netns/${NETNS_NAME}"
  mkdir -p "$netns_dir"
  [ -r /etc/resolv.conf ] && cp /etc/resolv.conf "$netns_dir/resolv.conf" || echo "nameserver 8.8.8.8" > "$netns_dir/resolv.conf"
  
  "$IP_CMD" link add "${VETH_HOST}" type veth peer name "${VETH_NS}"
  "$IP_CMD" link set "${VETH_HOST}" up
  "$IP_CMD" link set "${VETH_NS}" netns "${NETNS_NAME}"
  "$IP_CMD" addr add "${VETH_HOST_IP}/24" dev "${VETH_HOST}"
  
  "$IP_CMD" netns exec "${NETNS_NAME}" "$IP_CMD" link set lo up
  "$IP_CMD" netns exec "${NETNS_NAME}" "$IP_CMD" link set "${VETH_NS}" up
  "$IP_CMD" netns exec "${NETNS_NAME}" "$IP_CMD" addr add "${VETH_NS_IP}/24" dev "${VETH_NS}"
  "$IP_CMD" netns exec "${NETNS_NAME}" "$IP_CMD" route add default via "${VETH_HOST_IP}"
  
  # Record the values before changing them: cleanup only restores switches that "were off and turned on by us", so other programs
  # on the machine that really rely on forwarding=1 (container runtimes, forwarding services, etc.) are not affected.
  printf 'SYSCTL_IPFWD_ORIG=%s\nSYSCTL_V6FWD_ORIG=%s\n' \
    "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)" \
    "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo unknown)" \
    > "$SYSCTL_STATE_FILE" 2>/dev/null || true
  log_info "Enabling kernel IP forwarding..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  # v8: IPv6 forwarding is off by default (not needed when netns has no IPv6 egress, and enabling it globally may stop the host accepting RA); only enabled with IPV6_FORWARD=on
  if [ "${OCM_IPV6_FORWARD:-0}" = 1 ]; then sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null; fi

  log_info "Configuring MASQUERADE for Netns egress traffic..."
  local gw_dev; gw_dev=$("$IP_CMD" route | awk '/^default/ {print $5; exit}')
  if [ -n "$gw_dev" ]; then
    local MASQUERADE_RULE="-s ${VETH_SUBNET} ! -o ${VETH_HOST} -j MASQUERADE"
    "$IPTABLES_CMD" -t nat -D POSTROUTING ${MASQUERADE_RULE} 2>/dev/null || true
    "$IPTABLES_CMD" -t nat -A POSTROUTING ${MASQUERADE_RULE}
  else
    log_warn "Could not find default gateway device, may not be able to configure egress NAT for Netns"
  fi
  
  log "Netns environment is ready."
}
cleanup_netns() {
  log_info "Cleaning up Network Namespace base configuration..."
  
  local MASQUERADE_RULE="-s ${VETH_SUBNET} ! -o ${VETH_HOST} -j MASQUERADE"
  "$IPTABLES_CMD" -t nat -D POSTROUTING ${MASQUERADE_RULE} 2>/dev/null || true
  
  "$IP_CMD" netns del "${NETNS_NAME}" 2>/dev/null || true
  "$IP_CMD" link del "${VETH_HOST}" 2>/dev/null || true
  # setup_netns puts a resolv.conf into /etc/netns/<name>/ (ip netns exec
  # bind-mounts it over /etc/resolv.conf). Remove it here too, otherwise every Netns-mode run leaves
  # a directory on the system that survives even after the script is uninstalled.
  rm -rf "/etc/netns/${NETNS_NAME}" 2>/dev/null || true
  # Restore the forwarding switches: only restore to 0 if the original value was 0 (i.e. turned on by this script); otherwise leave it alone.
  if [ -f "$SYSCTL_STATE_FILE" ]; then
    local _ipfwd_orig="" _v6fwd_orig=""
    _ipfwd_orig=$(grep '^SYSCTL_IPFWD_ORIG=' "$SYSCTL_STATE_FILE" 2>/dev/null | cut -d'=' -f2 || true)
    _v6fwd_orig=$(grep '^SYSCTL_V6FWD_ORIG=' "$SYSCTL_STATE_FILE" 2>/dev/null | cut -d'=' -f2 || true)
    if [ "$_ipfwd_orig" = "0" ]; then
      sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
      log_info "Restored net.ipv4.ip_forward to 0 (it was 0 before the script started)"
    fi
    if [ "$_v6fwd_orig" = "0" ]; then
      sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
      log_info "Restored net.ipv6.conf.all.forwarding to 0 (it was 0 before the script started)"
    fi
    rm -f "$SYSCTL_STATE_FILE" 2>/dev/null || true
  fi
  log "Netns base environment has been cleaned up."
}

# --- Account management ---
manage_accounts() {
  [ -f "$ACCOUNTS_FILE" ] || { tee "$ACCOUNTS_FILE" >/dev/null <<'EOT'
# Format: DisplayName|Username|Password|VPNHost|AuthGroup(optional)|Protocol(optional)
EOT
    chmod 600 "$ACCOUNTS_FILE" || true; }
  # c must be local: otherwise the submenu overwrites the main menu's choice variable with its own choice, and after returning
  # the "press any key?" check (end of main_menu) uses the wrong value, showing up as an extra
  # "Press any key to return to the main menu" pause out of nowhere - which also swallows the next typed option.
  local c
  while true; do
    clear 2>/dev/null || true; title "🔐 Manage VPN Accounts ($ACCOUNTS_FILE)"; sep
    accounts_list   # v8: the list no longer shows the password column
    sep; echo "  1) Add  2) Delete  3) Back"; read -rp "Select [1-3]: " c || { echo; log_info "Standard input ended, returning."; return 0; }
    case "$c" in
      1) read -rp "Display name: " d; read -rp "Username: " u; read -sp "Password: " p; echo; read -rp "Host: " h; read -rp "Auth group (optional): " g; read -rp "Protocol (optional, empty = global protocol from settings; anyconnect/pulse/nc/gp/fortinet/array): " pr
         case "${pr:-}" in ""|anyconnect|pulse|nc|gp|fortinet|array) ;; *) log_err "Unknown protocol: $pr"; read -n1 -s -p "Press any key to continue"; continue;; esac
         [ -z "$d" ] || [ -z "$u" ] || [ -z "$p" ] || [ -z "$h" ] && { log_err "Required fields cannot be empty"; read -n1 -s -p "Press any key to continue"; continue; }
         # The accounts file separates fields with | (cut -d'|'); any field containing | shifts the fields (password pa|ss would be read as pa)
         case "$d$u$p$h$g$pr" in *"|"*) log_err "No field may contain the | character"; read -n1 -s -p "Press any key to continue"; continue;; esac
         echo "$d|$u|$p|$h|$g${pr:+|$pr}" >> "$ACCOUNTS_FILE"; chmod 600 "$ACCOUNTS_FILE" || true; log "Added $d"; read -n1 -s -p "Press any key to continue";;
      2) mapfile -t A < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE"); [ ${#A[@]} -eq 0 ] && { log_info "No accounts found"; sleep 1; continue; }
         read -rp "Enter the number to delete: " i; [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#A[@]}" ] || { log_err "Invalid number"; continue; }
         # Delete exactly one line by "the i-th entry of the filtered list". The old grep -vF on the whole line had two pitfalls:
         # (1) when deleting the last entry grep prints nothing and returns 1, so `&& mv` does not run - the file is untouched yet
         #    "Deleted" is printed anyway (fake success), leaving a .tmp behind; (2) two identical account lines would both be deleted.
         if ! awk -v n="$i" 'BEGIN{k=0} /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next} {k++; if (k!=n) print}' "$ACCOUNTS_FILE" > "${ACCOUNTS_FILE}.tmp"; then
           log_err "Delete failed: cannot write the temporary file."; rm -f "${ACCOUNTS_FILE}.tmp"; read -n1 -s -p "Press any key to continue"; continue
         fi
         mv "${ACCOUNTS_FILE}.tmp" "$ACCOUNTS_FILE"; chmod 600 "$ACCOUNTS_FILE" || true; log "Deleted"; read -n1 -s -p "Press any key to continue";;
      3) break;;
      *) log_err "Invalid option"; sleep 1;;
    esac
  done
}

# ============================================================================
#  Settings (/etc/oc-master/settings.conf, 600)
# ----------------------------------------------------------------------------
#  Each registry row: KEY|type|default|choices|title|group
#    type: choice (only the listed choices), int (number; choices are just common presets), text (free text,
#          choices are presets), account (account index), auth (SOCKS username+password)
#    choices: comma-separated value:description
#  The description texts live in _set_help, shared by the menu and `ocm config list -v`.
# ============================================================================
SET_REGISTRY=(
  "ACCOUNT|account|1||VPN account|Connection"
  "MODE|choice|netns|netns:Netns isolated proxy (recommended),default:Default global mode,ocproxy:ocproxy user-space proxy|Run mode|Connection"
  "PROTOCOL|choice|anyconnect|anyconnect:Cisco AnyConnect,pulse:Pulse / Ivanti Secure Access,nc:Juniper Network Connect,gp:Palo Alto GlobalProtect,fortinet:Fortinet SSL VPN,array:Array Networks|VPN protocol|Connection"
  "DATA_CHANNEL|choice|dtls|dtls:ESP/DTLS (UDP; openconnect default),tls:TLS only (--no-dtls)|Data channel|Connection"
  "RECONNECT_TIMEOUT|int|300|60:1 minute,300:5 minutes (openconnect default),900:15 minutes|Reconnect timeout on network loss (s)|Connection"
  "MTU|text|auto|auto:Auto,1400:1400,1300:1300,1200:1200|Tunnel MTU|Connection"
  "OC_EXTRA|text|||Extra openconnect arguments|Connection"
  "SOCKS_PORT|int|1080|1080:1080,8585:8585|SOCKS5 port|Proxy"
  "LISTEN|choice|127.0.0.1|127.0.0.1:Local only (access via SSH tunnel),0.0.0.0:All interfaces (publicly exposed)|Listen scope|Proxy"
  "SOCKS_AUTH|auth|||SOCKS5 authentication|Proxy"
  "FORWARDER|choice|socat|socat:socat process relay (IPv4+IPv6 entry),iptables:iptables double NAT (IPv4 entry only)|Port forwarding method|Proxy"
  "KILL_SWITCH|choice|off|off:Off (proxy uses the VPS egress while the VPN is down),on:On (proxy fails outright while the VPN is down)|Kill switch|Security"
  "DNS_FAST|choice|off|off:System default (waits 5 s each time),on:Fast retry (1 s × 3 attempts; rotating servers)|DNS timeout policy|Network"
  "IPV6_FORWARD|choice|off|off:Off,on:On|Host IPv6 forwarding|Network"
  "AUTO_RECONNECT|choice|on|on:On,off:Off|Auto reconnect|Supervisor"
  "BACKOFF|text|5 30 60 120 300 600 900|5 30 60 120 300 600 900:Default,10 60 300 900:Conservative|Reconnect backoff (s)|Supervisor"
  "MAX_PER_HOUR|int|12|6:6 times,12:12 times,30:30 times|Max reconnects per hour|Supervisor"
  "AUTH_FAIL_PAUSE|int|3|1:1 time,3:3 times,5:5 times|Auth failure pause threshold|Supervisor"
  "DEGRADED_WAIT|int|90|30:30 s,60:60 s,90:90 s,180:180 s|Soft reconnect after tunnel is unusable for|Supervisor"
  "AUTOSTART|choice|off|off:Off,on:On|Connect automatically at boot|Supervisor"
  "WATCH|choice|on|on:On,off:Off|Diagnostic log|Logging"
  "SAMPLE_INTERVAL|int|30|15:15 s,30:30 s,60:60 s|Sample interval (s)|Logging"
  "LOG_MAX_MB|int|300|100:100 MB,300:300 MB,1000:1 GB|Total log size limit (MB)|Logging"
  "EXTRA_PROBE_URL|text|||Extra probe URL|Logging"
)
# Storage keys (SOCKS_AUTH combines two items; actually stored as SOCKS_USER / SOCKS_PASS)
declare -A CFG=() SET_TYPE=() SET_DEF=() SET_CHOICES=() SET_TITLE=() SET_GROUP=()
SET_KEYS=()
for _e in "${SET_REGISTRY[@]}"; do
  IFS='|' read -r _k _t _d _c _ti _g <<<"$_e"
  SET_KEYS+=("$_k"); SET_TYPE[$_k]=$_t; SET_DEF[$_k]=$_d; SET_CHOICES[$_k]=$_c; SET_TITLE[$_k]=$_ti; SET_GROUP[$_k]=$_g
done
unset _e _k _t _d _c _ti _g
# Keys that need a VPN restart to take effect after a change (supervisor/logging keys are read live while running)
SET_NEEDS_RESTART=" ACCOUNT MODE PROTOCOL DATA_CHANNEL RECONNECT_TIMEOUT MTU OC_EXTRA SOCKS_PORT LISTEN SOCKS_AUTH FORWARDER KILL_SWITCH DNS_FAST IPV6_FORWARD "

_set_help() {
  case "$1" in
    ACCOUNT) echo "Which account in the accounts file (${ACCOUNTS_FILE}) to use. Accounts are added/removed via [Manage VPN accounts] in the main menu.";;
    MODE) cat <<'EOT'
netns   : the VPN is confined to a separate network namespace and exposed as a SOCKS5 proxy; local SSH and other services are completely unaffected.
          Suits "only some programs should go through the school/company network". Needs gost (SOCKS5 server) plus socat or iptables.
default : all host traffic goes through the VPN (SSH protection routes are set up automatically so you are not locked out). Changes the egress of every service on this host;
          the first start comes with a 3-minute automatic fallback rollback.
ocproxy : user-space SOCKS5 (no kernel tun), IPv4 only, no auth, listens locally only; the lightest option.
EOT
;;
    PROTOCOL) echo "Type of the VPN server; must match the server (if unsure, check your school/company VPN help page or client name).
An individual account can set its own protocol in column 6 of the accounts file, which overrides this global value.";;
    DATA_CHANNEL) echo "dtls: connects over TLS first, after about 1 minute data moves to UDP (ESP/DTLS) - lower latency, higher throughput;
      but less stable on lossy networks or networks that restrict UDP.
tls : all traffic goes through the TLS/TCP tunnel (--no-dtls). Slightly more overhead, usually more stable on lossy networks.
      Measured: on a Juniper gateway with heavy daytime UDP loss, switching to tls halved the proxy failure rate.";;
    RECONNECT_TIMEOUT) echo "How long openconnect itself keeps trying to resume after a network blip before giving up (--reconnect-timeout).
Note: when the server ends the session (e.g. session expiry) openconnect exits immediately; this value does not apply, [Auto reconnect] below handles it.";;
    MTU) echo "Maximum tunnel packet size. auto lets openconnect negotiate with the server; if pages load but large files/some sites stall, try 1400 or 1300.";;
    OC_EXTRA) echo "Arguments appended verbatim to openconnect (space-separated), e.g. --useragent=xxx or --os=win.
Leave empty for none. Advanced option: wrong values will make the connection fail.";;
    SOCKS_PORT) echo "SOCKS5 proxy listen port (netns / ocproxy mode). Must not be in use.";;
    LISTEN) echo "127.0.0.1: only this host can connect; from your own computer use an SSH tunnel: ssh -L port:127.0.0.1:port your-VPS.
0.0.0.0  : anyone can reach this port - be sure to enable SOCKS5 authentication as well and restrict sources with a firewall.
(ocproxy mode always listens locally only.)";;
    SOCKS_AUTH) echo "Set a SOCKS5 username/password (netns mode only). Strongly recommended when listening publicly.
Username must not contain @ : / quotes backslash whitespace; password must not contain / quotes backslash whitespace (they break URL parsing).";;
    FORWARDER) echo "Forwards the host port to the SOCKS5 server inside netns:
socat   : process-level relay, reachable over both IPv4+IPv6 on the host side, the safest choice (default).
iptables: kernel double NAT, no extra process, but IPv4 entry only.";;
    KILL_SWITCH) echo "Off: during the few seconds the VPN is down/reconnecting the proxy still responds, but traffic leaves via the VPS's own IP.
On: when the VPN is down the proxy fails outright (the firewall inside netns only allows the tunnel), so traffic never leaves via the VPS egress;
    the cost is that requests error out while reconnecting. Netns mode only.";;
    DNS_FAST) echo "If the DNS pushed by the VPN often drops packets, programs wait 5 seconds for every lost query, so pages hang now and then.
on: adds options timeout:1 attempts:3 rotate to the netns resolv.conf, retrying after 1 second and rotating servers on loss.
Netns mode only; re-applied automatically after every (re)connect (vpnc-script rewrites that file on every connect).";;
    IPV6_FORWARD) echo "Netns mode needs IPv4 forwarding on the host (enabled automatically, restored to the original value after stop). IPv6 forwarding is only needed if the VPN pushes
IPv6 and you want IPv6 through the proxy; enabling it globally may stop the host accepting IPv6 router advertisements (RA). If unsure, keep it off.";;
    AUTO_RECONNECT) echo "Reconnect automatically after openconnect exits (server session expiry -> reconnect after about 2 seconds; network error -> retry with backoff;
auth failure -> counted, pause once the threshold is reached so the account is not locked). When off, a disconnect stops and cleans up.";;
    BACKOFF) echo "Retry interval sequence (seconds) for network failures; the Nth failure uses the Nth value, beyond that the last one. Server session expiry does not use backoff.";;
    MAX_PER_HOUR) echo "Max reconnects within 1 hour; beyond that wait until the window slides. Prevents frantic retries from triggering server risk controls on errors.";;
    AUTH_FAIL_PAUSE) echo "Pause auto reconnect after this many consecutive auth failures (wrong password/account rejected), so the account is not locked.
An auth failure on the very first start stops immediately. To resume: check the account, then ocm heal on or start again.";;
    DEGRADED_WAIT) echo "If the openconnect process is still alive but access through the proxy keeps failing for this many seconds, disconnect and reconnect (soft reconnect).
Too short and UDP channel switches or brief jitter trigger it falsely; too long and a stuck connection takes longer to recover.";;
    AUTOSTART) echo "Connect automatically at boot with the current settings (enables the systemd unit ocm.service).";;
    WATCH) echo "Background diagnostic service (ocm-watch.service): periodically samples tunnel/proxy/gateway state, records state changes and disconnect snapshots,
and performs the soft reconnect when [process alive but not working]. Logs are in ${LOG_DIR}; ocm log report shows a summary.";;
    SAMPLE_INTERVAL) echo "Diagnostic sample interval. After a state change it automatically tightens to 5 seconds for 3 minutes; otherwise this value is used.";;
    LOG_MAX_MB) echo "Total size limit of the diagnostic log directory; when exceeded, the oldest rotated files are deleted first. Sampling pauses when free disk space drops below 400MB.";;
    EXTRA_PROBE_URL) echo "A URL accessed through the proxy in addition to the public probe (e.g. a library database portal), to confirm campus resources are reachable. Leave empty to skip.";;
  esac
}

settings_defaults() { local k; for k in "${SET_KEYS[@]}"; do CFG[$k]=${SET_DEF[$k]}; done; CFG[SOCKS_USER]=""; CFG[SOCKS_PASS]=""; }
_is_cfg_key() { case " ${SET_KEYS[*]} SOCKS_USER SOCKS_PASS " in *" $1 "*) [ "$1" != SOCKS_AUTH ];; *) return 1;; esac; }

# Read a file of KEY=<printf %q value> lines into CFG (whitelisted keys only; the file is writable by root only)
_load_kv_file() {
  local f="$1" line k v
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]}; _is_cfg_key "$k" || continue
    eval "v=${BASH_REMATCH[2]}" 2>/dev/null || continue
    CFG[$k]=$v
  done < "$f"
}
settings_load() { settings_defaults; _load_kv_file "$SETTINGS_FILE"; }

settings_save() {
  local k tmp
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR" 2>/dev/null || true
  tmp=$(mktemp "${SETTINGS_FILE}.XXXXXX")
  {
    echo "# oc-master settings (generated by ocm; change via the ocm [Settings] menu or ocm config set)"
    for k in "${SET_KEYS[@]}" SOCKS_USER SOCKS_PASS; do
      [ "$k" = SOCKS_AUTH ] && continue
      printf '%s=%q\n' "$k" "${CFG[$k]:-}"
    done
  } > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$SETTINGS_FILE"
}

# Validation: returns 0 on success; on failure prints the reason and returns 1
settings_validate() {
  local k="$1" v="$2" c ok=0 n
  case "$k" in
    SOCKS_PORT) [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || { log_err "Port must be 1-65535"; return 1; }; return 0;;
    MTU) [ "$v" = auto ] || { [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 576 ] && [ "$v" -le 9000 ]; } || { log_err "MTU must be auto or 576-9000"; return 1; }; return 0;;
    BACKOFF) [[ "$v" =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]] || { log_err "Backoff must be space-separated seconds, e.g. 5 30 60"; return 1; }; return 0;;
    ACCOUNT) n=$(accounts_count); [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le "${n:-0}" ] || { log_err "Account index must be 1-${n:-0}"; return 1; }; return 0;;
    SOCKS_USER) [ -z "$v" ] && return 0
      case "$v" in *@*|*:*|*/*|*\"*|*\'*|*\\*|*[[:space:]]*) log_err "Username must not contain @ : / quotes backslash whitespace"; return 1;; esac; return 0;;
    SOCKS_PASS) [ -z "$v" ] && return 0
      case "$v" in */*|*\"*|*\'*|*\\*|*[[:space:]]*) log_err "Password must not contain / quotes backslash whitespace"; return 1;; esac; return 0;;
    OC_EXTRA|EXTRA_PROBE_URL) case "$v" in *$'\n'*) log_err "Must not contain newlines"; return 1;; esac; return 0;;
  esac
  case "${SET_TYPE[$k]:-}" in
    choice) IFS=',' read -r -a _cs <<<"${SET_CHOICES[$k]}"
            for c in "${_cs[@]}"; do [ "${c%%:*}" = "$v" ] && ok=1; done
            [ $ok = 1 ] || { log_err "$k must be one of: $(for c in "${_cs[@]}"; do printf '%s ' "${c%%:*}"; done)"; return 1; } ;;
    int) [[ "$v" =~ ^[0-9]+$ ]] || { log_err "$k must be an integer"; return 1; } ;;
    "") log_err "Unknown setting: $k"; return 1;;
  esac
  return 0
}

# For display: value -> description
cfg_label() {
  local k="$1" v="${2-${CFG[$1]:-}}" c
  case "$k" in
    SOCKS_AUTH) if [ -n "${CFG[SOCKS_USER]:-}" ]; then echo "${CFG[SOCKS_USER]}:****"; else echo "none"; fi; return;;
    ACCOUNT) echo "${v}) $(account_field "$v" 1 2>/dev/null || echo '?')"; return;;
    OC_EXTRA|EXTRA_PROBE_URL) echo "${v:-(empty)}"; return;;
  esac
  IFS=',' read -r -a _cs <<<"${SET_CHOICES[$k]:-}"
  for c in "${_cs[@]}"; do [ "${c%%:*}" = "$v" ] && { echo "${c#*:}"; return; }; done
  echo "$v"
}

# ============================================================================
#  Accounts (/root/.vpn_accounts.env)
#  Format: DisplayName|Username|Password|VPNHost|AuthGroup(optional)|Protocol(optional, overrides the global PROTOCOL)
#  The password is read only inside the supervisor and handed to openconnect via stdin; never exported, never printed.
# ============================================================================
_accounts_lines() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ACCOUNTS_FILE" 2>/dev/null || true; }
accounts_count() { _accounts_lines | wc -l; }
# account_field <index> <column> (only fetches the needed column; never column 3 for display)
account_field() { _accounts_lines | awk -F'|' -v n="$1" -v c="$2" 'NR==n{print $c; f=1} END{exit !f}'; }
# Resolve a name or index to an index
account_resolve() {
  local a="$1"
  if [[ "$a" =~ ^[0-9]+$ ]]; then [ "$a" -ge 1 ] && [ "$a" -le "$(accounts_count)" ] && { echo "$a"; return 0; }; return 1; fi
  _accounts_lines | awk -F'|' -v a="$a" '$1==a{print NR; f=1; exit} END{exit !f}'
}
# Load an account into global variables (not exported)
account_load() {
  local line
  line=$(_accounts_lines | sed -n "${1}p")
  [ -n "$line" ] || { log_err "Account #$1 does not exist (${ACCOUNTS_FILE})"; return 1; }
  IFS='|' read -r VPN_DESC VPN_USER VPN_PASS VPN_HOST VPN_GROUP VPN_ACC_PROTO <<<"$line"
  [ -n "$VPN_USER" ] && [ -n "$VPN_PASS" ] && [ -n "$VPN_HOST" ] || { log_err "Account #$1 is missing username/password/host"; return 1; }
  return 0
}
accounts_list() {
  local n=0 name user host grp proto
  [ -f "$ACCOUNTS_FILE" ] || { echo "  (accounts file does not exist: $ACCOUNTS_FILE)"; return 0; }
  while IFS='|' read -r name user _ host grp proto; do
    n=$((n+1)); printf '  %d) %s  user:%s  host:%s%s%s\n' "$n" "$name" "$user" "$host" \
      "${grp:+  group:$grp}" "${proto:+  protocol:$proto}"
  done < <(_accounts_lines)
  [ $n -gt 0 ] || echo "  (no accounts)"
}
gw_host_of() { local h; h=$(account_field "$1" 4 2>/dev/null || true); h=${h#https://}; h=${h#http://}; h=${h%%/*}; h=${h%%:*}; printf '%s' "$h"; }

# --- Stop & cleanup ---
cleanup_ssh_protect_routes() {
  local vps4="" vps6=""
  if [ -f "$STATE_FILE" ]; then
    log_info "🔍 Loading routing info from the state file for precise cleanup..."
    # || true: if the state file exists but lacks this key, grep returns 1, the assignment fails, and set -e would
    # abort the whole cleanup (measured: exited without cleaning a single field, all policy routes left behind).
    vps4=$(grep '^VPS4=' "$STATE_FILE" | cut -d'=' -f2 || true)
    vps6=$(grep '^VPS6=' "$STATE_FILE" | cut -d'=' -f2 || true)
  else
    log_warn "State file not found, attempting generic cleanup."
  fi

  [ -n "$vps4" ] && { "$IP_CMD" rule del from "$vps4" table "$RT4_NAME" priority 500 2>/dev/null || true; log "Attempted to clean up IPv4 rule (from $vps4)"; }
  [ -n "$vps6" ] && { "$IP_CMD" -6 rule del from "$vps6" table "$RT6_NAME" priority 500 2>/dev/null || true; log "Attempted to clean up IPv6 rule (from $vps6)"; }
  
  log_info "🧹 Cleaning up all leftover rules pointing to $RT4_NAME and $RT6_NAME..."
  while "$IP_CMD" rule del table "$RT4_NAME" 2>/dev/null; do log "  -> Removed an orphaned IPv4 rule"; done
  while "$IP_CMD" -6 rule del table "$RT6_NAME" 2>/dev/null; do log "  -> Removed an orphaned IPv6 rule"; done

  "$IP_CMD" route flush table "$RT4_ID" 2>/dev/null || true
  "$IP_CMD" -6 route flush table "$RT6_ID" 2>/dev/null || true
  log "✅ Policy routes completely cleaned up"
}

# ============================================================================
#  Port forwarding backends (self-contained module - new schemes only touch this section)
# ----------------------------------------------------------------------------
#  Inside netns the VPN is global (default route default dev tun0), so "forwarding a host port to the gost
#  inside netns" has only two workable routes, each implemented as a self-contained backend that the main flow calls by name:
#
#    socat    - process-level relay (preferred). client<->socat and socat<->gost are two separate connections,
#                both ends of the host<->netns leg are on the directly connected veth subnet, so no return routing is needed.
#    iptables - double NAT (fallback). DNAT sends the packet into netns, SNAT rewrites the source to the host veth address.
#                Without SNAT it is dead: if the destination of gost's reply is not on the veth subnet, 127.0.0.1
#                goes to lo and never leaves netns, other addresses are swallowed by tun0, and the client never gets a reply.
#                Measured locally: with DNAT only, all four access paths failed; adding one SNAT rule made them all work at once.
#
#  Unified entry points (the main flow only knows these three):
#     _fwd_avail <name>                    -> is this backend currently usable
#     _fwd_setup <backend> <port> <listen addr> -> 0=success, and fills _FWD_DESC / _FWD_STATE
#     _fwd_teardown <backend>             -> tears down by the rule strings in state, safe to call repeatedly
#  The backend is decided directly by the menu item (3=socat / 4=iptables); there is no longer a "choose preference" step.
#  New backend: write _fwd_setup_<name> and _fwd_teardown_<name>, add a line in _fwd_avail and each dispatcher
#            and an item in the menu; the main flow, stop flow and status display need no changes.
# ============================================================================
_FWD_DESC=""    # backend actually used (written as FORWARDER into state)
_FWD_STATE=""   # extra lines to write into the state file

_fwd_avail() {
  case "$1" in
    socat)    command -v socat &>/dev/null ;;
    iptables) command -v iptables &>/dev/null || [ -x "$IPTABLES_CMD" ] ;;
    *)        return 1 ;;
  esac
}

_fwd_setup() {
  case "$1" in
    socat|iptables) "_fwd_setup_$1" "$2" "$3" ;;
    *) log_err "Unknown forwarding backend: $1"; return 1 ;;
  esac
}
_fwd_teardown() {
  case "${1:-}" in
    socat|iptables) "_fwd_teardown_$1" ;;
    *)
      # State from older versions may lack the FORWARDER key yet leave RULE_* rule strings; clean them once as a fallback
      if [ -n "${RULE_DNAT_OUTPUT:-}" ] || [ -n "${RULE_DNAT_PREROUTING:-}" ] || [ -n "${RULE_SNAT:-}" ] || [ -n "${RULE_FORWARD:-}" ]; then
        _fwd_teardown_iptables
      fi
      return 0 ;;
  esac
}

# --- Backend 1: socat (process-level relay, default and preferred) ---
_fwd_setup_socat() {
  local socks_port="$1" listen_addr="$2" pid_v4="" pid_v6=""
  socat TCP4-LISTEN:"${socks_port}",bind="${listen_addr}",fork,reuseaddr TCP4:"${VETH_NS_IP}:${socks_port}" >/dev/null 2>&1 &
  pid_v4=$!; echo "$pid_v4" > "$SOCAT_PID_FILE"
  sleep 1; if ! kill -0 "$pid_v4" 2>/dev/null; then log_err "socat port forwarding failed to start"; return 1; fi
  if [[ "$listen_addr" == "0.0.0.0" ]] || [[ "$listen_addr" == "::" ]]; then
    socat TCP6-LISTEN:"${socks_port}",ipv6only=1,fork,reuseaddr TCP4:"${VETH_NS_IP}:${socks_port}" >/dev/null 2>&1 &
    pid_v6=$!; echo "$pid_v6" > "$SOCAT_PID_FILE_V6"
    log "Port forwarding via socat is up (IPv4 PID: $pid_v4, IPv6 PID: $pid_v6)"
  else
    log "Port forwarding via socat is up (PID: $pid_v4)"
  fi
  _FWD_DESC="socat"; _FWD_STATE="SOCAT_PID=${pid_v4}"
  [ -n "$pid_v6" ] && _FWD_STATE="${_FWD_STATE}"$'\n'"SOCAT_PID_V6=${pid_v6}"
  return 0
}
_fwd_teardown_socat() {
  [ -f "$SOCAT_PID_FILE" ] && kill "$(cat "$SOCAT_PID_FILE")" 2>/dev/null || true
  [ -f "$SOCAT_PID_FILE_V6" ] && kill "$(cat "$SOCAT_PID_FILE_V6")" 2>/dev/null || true
  return 0
}

# --- Backend 2: iptables double NAT (fallback when socat is absent) ---
_fwd_setup_iptables() {
  # Must be split into two locals: within one local statement ${socks_port} is not yet in effect when expanded,
  # so bash looks up a same-named variable up the call chain (dynamic scoping). It only works now by luck because _start_netns_logic
  # has a same-named local; called from anywhere else, dst would become "192.168.200.2:" (empty port).
  local socks_port="$1" listen_addr="$2"
  local dst="${VETH_NS_IP}:${socks_port}"
  local R_OUT R_PRE="" R_SNAT
  R_SNAT="-p tcp -d ${VETH_NS_IP} --dport ${socks_port} -j SNAT --to-source ${VETH_HOST_IP}"
  # Clear the leftover OUTPUT rule from older versions once: the old "open to all" rule had no addrtype restriction; if the state file
  # is lost (/var/run cleared, or a cross-mode failure) it can neither be deleted nor found - and it sits ahead of the new rule,
  # so local traffic to the same port on external hosts is still hijacked, showing up as "upgraded but nothing changed".
  "$IPTABLES_CMD" -t nat -D OUTPUT -p tcp --dport "${socks_port}" -j DNAT --to-destination "${dst}" 2>/dev/null || true
  if [ "$listen_addr" = "0.0.0.0" ] || [ "$listen_addr" = "::" ]; then
    # Open to all: locally generated traffic goes through OUTPUT, external traffic through PREROUTING; both are needed.
    # The OUTPUT rule uses addrtype to restrict to "destination is a local address": it covers 127.0.0.1 and the host's private IP
    # (for the latter, measured, PREROUTING alone does not connect - local traffic never passes PREROUTING), without
    # hijacking local traffic to the same port on external hosts. addrtype verified working: the counter increases when the destination is a local address
    # and stays unchanged when the destination is 1.1.1.1.
    R_OUT="-p tcp -m addrtype --dst-type LOCAL --dport ${socks_port} -j DNAT --to-destination ${dst}"
    R_PRE="-p tcp --dport ${socks_port} -j DNAT --to-destination ${dst}"
  else
    # Local listen only: restrict the destination to 127.0.0.1 and add no PREROUTING - same semantics as socat bind 127.0.0.1
    R_OUT="-p tcp -d 127.0.0.1 --dport ${socks_port} -j DNAT --to-destination ${dst}"
  fi
  # Key precondition: after OUTPUT DNAT, locally generated traffic still has source address 127.0.0.1. After DNAT
  # netfilter re-routes the packet (ip_route_me_harder), and the kernel uses route_localnet to decide whether
  # 127.0.0.0/8 may leave "this interface"; the default 0 = no, the packet is dropped as a martian,
  # never even reaching POSTROUTING (measured: DNAT counter keeps rising, SNAT counter stays 0, nothing captured on veth).
  # The kernel value is IN_DEV_ORCONF - all and the interface value are ORed, so enabling just this veth is enough,
  # no need to touch the global all; the impact is limited to the interface this script creates, and the setting disappears with the veth.
  sysctl -w "net.ipv4.conf.${VETH_HOST}.route_localnet=1" >/dev/null 2>&1 || true

  # -C first, then -A: repeated runs do not stack rules
  "$IPTABLES_CMD" -t nat -C OUTPUT $R_OUT 2>/dev/null || "$IPTABLES_CMD" -t nat -A OUTPUT $R_OUT \
    || { log_err "Failed to add iptables DNAT (local)"; return 1; }
  "$IPTABLES_CMD" -t nat -C POSTROUTING $R_SNAT 2>/dev/null || "$IPTABLES_CMD" -t nat -A POSTROUTING $R_SNAT \
    || { log_err "Failed to add iptables SNAT"; return 1; }
  if [ -n "$R_PRE" ]; then
    "$IPTABLES_CMD" -t nat -C PREROUTING $R_PRE 2>/dev/null || "$IPTABLES_CMD" -t nat -A PREROUTING $R_PRE \
      || { log_err "Failed to add iptables DNAT (external)"; return 1; }
  fi
  _FWD_DESC="iptables"
  _FWD_STATE="RULE_DNAT_OUTPUT='${R_OUT}'"
  [ -n "$R_PRE" ] && _FWD_STATE="${_FWD_STATE}"$'\n'"RULE_DNAT_PREROUTING='${R_PRE}'"
  _FWD_STATE="${_FWD_STATE}"$'\n'"RULE_SNAT='${R_SNAT}'"
  log "Port forwarding via iptables double NAT is up (DNAT -> ${dst}, SNAT -> ${VETH_HOST_IP})"
  return 0
}
_fwd_teardown_iptables() {
  # Covers both this version (RULE_DNAT_*/RULE_SNAT) and the RULE_FORWARD left by older versions
  local k="" r=""
  for k in RULE_DNAT_OUTPUT RULE_DNAT_PREROUTING RULE_SNAT RULE_FORWARD; do
    r="${!k:-}"
    [ -n "$r" ] || continue
    case "$k" in
      RULE_DNAT_OUTPUT)     eval "\$IPTABLES_CMD -t nat -D OUTPUT ${r}" 2>/dev/null || true ;;
      RULE_DNAT_PREROUTING) eval "\$IPTABLES_CMD -t nat -D PREROUTING ${r}" 2>/dev/null || true ;;
      RULE_SNAT)            eval "\$IPTABLES_CMD -t nat -D POSTROUTING ${r}" 2>/dev/null || true ;;
      RULE_FORWARD)         eval "\$IPTABLES_CMD -D FORWARD ${r}" 2>/dev/null || true ;;
    esac
  done
  return 0
}

# v7's stop_vpn is kept verbatim as the low-level cleanup function (tears down each mode's processes, routes, netns per state).
_teardown_session() {
  # Must not return early when the state file exists: a failed start has already written state and set up policy routes; returning early would skip
  # cleanup_ssh_protect_routes and rm - leaving ip rules and state behind (measured 4 leftover ip rule lines;
  # with the guard job installed it would also reconnect with the bad account every 5 minutes).
  if ! is_vpn_running && ! [ -f "$GOST_PID_FILE" ] && ! [ -f "$SOCAT_PID_FILE" ] && ! [ -f "$STATE_FILE" ] && ! [ -f "$SYSCTL_STATE_FILE" ]; then log_info "VPN is not running"; return; fi
  log_info "Stopping VPN and cleaning up the environment...";
  # || true: this line is especially dangerous - the assignment is the last command of `[ -f ] && ...`, and a failure would terminate
  # the whole stop_vpn: processes not killed, temp files not removed, fallback job not cancelled (measured rc=1 and nothing cleaned).
  local MODE; [ -f "$STATE_FILE" ] && MODE=$(grep '^MODE=' "$STATE_FILE" | cut -d'=' -f2 || true)

  case "${MODE:-unknown}" in
    netns)
      log_info "Stopping netns mode..."
      if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE" 2>/dev/null || true
        # Teardown is left to the backend module: socat kills processes, iptables deletes rules; the main flow does not know rule shapes.
        # A FORWARDER=iptables left by older versions (storing only RULE_DNAT_*/RULE_FORWARD) also goes through here.
        _fwd_teardown "${FORWARDER:-}"
      fi
      [ -f "$GOST_PID_FILE" ] && kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
      if [ -f "$PID_FILE" ]; then
        local oc_pid; oc_pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
        # Same as default|ocproxy: the pid file may be a stale record, verify identity before signalling
        if [ -n "$oc_pid" ] && [ "$(cat /proc/${oc_pid}/comm 2>/dev/null)" = "openconnect" ]; then
          kill "$oc_pid" 2>/dev/null || true
          # Must wait for openconnect to exit by itself before tearing down netns/veth: it first logs out from the gateway,
          # and the logout goes over exactly this veth->NAT path (tearing it down first leaves it stuck on a TLS timeout, see _wait_pid_gone).
          _wait_pid_gone "$oc_pid"
        fi
      fi
      cleanup_netns
      ;;
    default|ocproxy)
      log_info "Stopping ${MODE} mode..."
      # Same reasoning as the netns branch: finishing up right after kill leaves an openconnect "still logging out" (measured: 1 second after stop
      # the process is still visible, exiting by itself only after about 2-3 seconds); a user restarting right away would fight with it.
      # In default mode the logout goes over eth0 while the policy routes are still in place, so wait for it to exit first, then clean the routes.
      local oc_pid=""
      [ -f "$PID_FILE" ] && oc_pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
      # Before signalling, confirm this pid really is openconnect: the pid file may be a stale record (e.g. the previous connection
      # was kill -9'd and could not unlink), and that pid may long since have been reused by the kernel for another process - killing and
      # waiting as-is would hurt it (_wait_pid_gone even escalates to SIGKILL at the end).
      if [ -n "$oc_pid" ] && [ "$(cat /proc/${oc_pid}/comm 2>/dev/null)" = "openconnect" ]; then
        kill "$oc_pid" 2>/dev/null || true
        _wait_pid_gone "$oc_pid"
      fi
      [ "$MODE" = "default" ] && cleanup_ssh_protect_routes
      ;;
    *)
      log_warn "State file missing or mode unknown, performing generic cleanup..."
      # When netns mode fails "before writing state" it lands exactly here (no MODE in state): likewise wait for
      # openconnect to exit before tearing down netns/veth, otherwise it gets stuck logging out (see _wait_pid_gone).
      local oc_pid=""; [ -f "$PID_FILE" ] && oc_pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
      if [ -n "$oc_pid" ] && [ "$(cat /proc/${oc_pid}/comm 2>/dev/null)" = "openconnect" ]; then
        kill "$oc_pid" 2>/dev/null || true
        _wait_pid_gone "$oc_pid"
      fi
      [ -f "$GOST_PID_FILE" ] && kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
      [ -f "$SOCAT_PID_FILE" ] && kill "$(cat "$SOCAT_PID_FILE")" 2>/dev/null || true
      [ -f "$SOCAT_PID_FILE_V6" ] && kill "$(cat "$SOCAT_PID_FILE_V6")" 2>/dev/null || true
      cleanup_ssh_protect_routes
      cleanup_netns
      ;;
  esac
  
  # SYSCTL_STATE_FILE is not removed unconditionally here: it is the only basis for "restoring the forwarding switches", and is only
  # removed by cleanup_netns after restoring. Otherwise, with a cross-mode sequence like "netns session kill -9'd -> user switches to default
  # mode -> this stop takes the default branch (no cleanup_netns call)", the record would be deleted
  # while ip_forward is already 1, leaving no basis for restoring it.
  rm -f "$PID_FILE" "$STATE_FILE" "$GOST_PID_FILE" "$SOCAT_PID_FILE" "$SOCAT_PID_FILE_V6"; log "All temporary files cleaned up, operation complete."
}

# ============================================================================
#  systemd management
# ----------------------------------------------------------------------------
#  ocm.service       -> `ocm _supervise`: build netns/routes -> run openconnect in the foreground -> reconnect by exit reason.
#                      KillMode=mixed: on stop only the supervisor gets SIGTERM; it lets openconnect
#                      log out first, then tears down the proxy and netns (in reverse order openconnect would hang on logout).
#  ocm-watch.service -> `ocm _watch`: read-only diagnostic sampling + requests a soft reconnect when [process alive but not working].
#  The VPN processes belong to systemd, not the login session: closing SSH does not take gost/socat/openconnect down with it.
# ============================================================================
svc_active() { systemctl is-active --quiet "$SVC_MAIN" 2>/dev/null; }
set_phase() { mkdir -p "$RUN_DIR"; printf '%s %s\n' "$1" "$(now_s)" > "$PHASE_FILE.tmp" && mv -f "$PHASE_FILE.tmp" "$PHASE_FILE"; }
get_phase() { awk '{print $1; exit}' "$PHASE_FILE" 2>/dev/null || true; }
get_phase_since() { awk '{print $2; exit}' "$PHASE_FILE" 2>/dev/null || true; }

_unit_main() { cat <<EOF
[Unit]
Description=OpenConnect Master (ocm) VPN supervisor
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${SCRIPT_PATH} _supervise
KillMode=mixed
TimeoutStopSec=45
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=3

[Install]
WantedBy=multi-user.target
EOF
}
_unit_watch() { cat <<EOF
[Unit]
Description=OpenConnect Master (ocm) diagnostic logger
After=network-online.target

[Service]
Type=simple
ExecStart=${SCRIPT_PATH} _watch
Restart=always
RestartSec=5
Nice=10
IOSchedulingClass=idle
MemoryMax=96M
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
}

install_units() {
  case "$SCRIPT_PATH" in /tmp/*|/var/tmp/*) log_err "The script is in a temporary directory ($SCRIPT_PATH); move it to a fixed location (e.g. /root/oc_master.sh) before using systemd management."; return 1;; esac
  command -v systemctl >/dev/null 2>&1 || { log_err "This system has no systemd; the v8 managed mode is unavailable."; return 1; }
  local changed=0 u content
  for u in main watch; do
    local path="$UNIT_DIR/$SVC_MAIN"; [ $u = watch ] && path="$UNIT_DIR/$SVC_WATCH"
    content="$(_unit_$u)"
    if [ "$(cat "$path" 2>/dev/null)" != "$content" ]; then printf '%s\n' "$content" > "$path"; changed=1; fi
  done
  [ $changed = 1 ] && systemctl daemon-reload
  apply_service_prefs
  return 0
}
uninstall_units() {
  systemctl disable --now "$SVC_WATCH" >/dev/null 2>&1 || true
  systemctl stop "$SVC_MAIN" >/dev/null 2>&1 || true
  systemctl disable "$SVC_MAIN" >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/$SVC_MAIN" "$UNIT_DIR/$SVC_WATCH"
  systemctl daemon-reload 2>/dev/null || true
}
# Sync the diagnostic service and boot autostart with the settings (acts only when the state differs)
apply_service_prefs() {
  [ -f "$UNIT_DIR/$SVC_WATCH" ] || return 0
  if [ "${CFG[WATCH]:-on}" = on ]; then
    systemctl is-enabled --quiet "$SVC_WATCH" 2>/dev/null || systemctl enable "$SVC_WATCH" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$SVC_WATCH" 2>/dev/null || systemctl start "$SVC_WATCH" >/dev/null 2>&1 || true
  else
    systemctl disable --now "$SVC_WATCH" >/dev/null 2>&1 || true
  fi
  if [ "${CFG[AUTOSTART]:-off}" = on ]; then
    systemctl is-enabled --quiet "$SVC_MAIN" 2>/dev/null || systemctl enable "$SVC_MAIN" >/dev/null 2>&1 || true
  else
    systemctl is-enabled --quiet "$SVC_MAIN" 2>/dev/null && systemctl disable "$SVC_MAIN" >/dev/null 2>&1 || true
  fi
  return 0
}

# ============================================================================
#  supervisor (run by systemd as `ocm _supervise`; do not call manually)
# ============================================================================
SUP_STOP=0; OC_PID=""; GOST_PID=""; SESSION_N=0; EVER_UP=0; OC_START=0; PAUSED_REASON=""
GW_NAME=""; GW_IP=""; LAUNCH_LOG=""
declare -A LIVE=()
OC_ARGS=(); OC_PREFIX=()
OC_KEY_RE='dead peer|DPD|reconnect|terminat|closed|fail|error|expired|exiting|cancel|establish|unexpected|time ?out|rekey|lost|disconnect|logout|refused|unauthor|denied|ESP|DTLS|keepalive|idle|session|killed|signal|Configured as'

sup_log() {
  local t; printf -v t '%(%F %T)T' -1
  printf '[%s] %s\n' "$t" "$*"
  [ -n "$LAUNCH_LOG" ] && printf '[%s] %s\n' "$t" "$*" >> "$LAUNCH_LOG" 2>/dev/null
  return 0
}
# Supervisor settings take effect live: re-read from the settings file every round, without touching this connection's parameters
live_reload() {
  local k; local -A bak=()
  for k in "${!CFG[@]}"; do bak[$k]=${CFG[$k]}; done
  settings_load
  for k in AUTO_RECONNECT BACKOFF MAX_PER_HOUR AUTH_FAIL_PAUSE; do LIVE[$k]=${CFG[$k]}; done
  for k in "${!bak[@]}"; do CFG[$k]=${bak[$k]}; done
}
sup_proto() { echo "${VPN_ACC_PROTO:-${CFG[PROTOCOL]}}"; }

sup_build_oc() {
  OC_ARGS=(openconnect "$VPN_HOST" "--protocol=$(sup_proto)" "--user=$VPN_USER" --passwd-on-stdin --non-inter)
  [ -n "${VPN_GROUP:-}" ] && OC_ARGS+=("--authgroup=$VPN_GROUP")
  [ "${CFG[DATA_CHANNEL]}" = tls ] && OC_ARGS+=(--no-dtls)
  [[ "${CFG[RECONNECT_TIMEOUT]}" =~ ^[0-9]+$ ]] && OC_ARGS+=("--reconnect-timeout=${CFG[RECONNECT_TIMEOUT]}")
  [ "${CFG[MTU]}" != auto ] && OC_ARGS+=("--mtu=${CFG[MTU]}")
  [ "${CFG[MODE]}" = ocproxy ] && OC_ARGS+=(--script-tun --script "ocproxy -k 30 -D ${CFG[SOCKS_PORT]}")
  # Default global mode uses a fixed interface name: the host may already have another tun0 (overlay network/other VPN), so "any tun" cannot be relied on
  [ "${CFG[MODE]}" = default ] && OC_ARGS+=("--interface=$OC_TUN_DEFAULT")
  [ "${CFG[MODE]}" = netns ] && [ "${CFG[KILL_SWITCH]}" = on ] && [ -n "$GW_IP" ] && OC_ARGS+=("--resolve=${GW_NAME}:${GW_IP}")
  if [ -n "${CFG[OC_EXTRA]}" ]; then local -a _x; read -r -a _x <<<"${CFG[OC_EXTRA]}"; OC_ARGS+=("${_x[@]}"); fi
  OC_PREFIX=(); [ "${CFG[MODE]}" = netns ] && OC_PREFIX=("$IP_CMD" netns exec "$NETNS_NAME")
  return 0
}

# openconnect output -> openconnect.log (timestamped), the current session file, journald; key lines go to events.log
oc_log_pipe() { # $1=session number $2=whether to write to the launch log
  local line t e
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | redact)
    printf -v t '%(%Y-%m-%dT%H:%M:%S%z)T' -1; printf -v e '%(%s)T' -1
    printf '%s openconnect[s%s] %s\n' "$t" "$1" "$line" >> "$OCLOG" 2>/dev/null
    printf '%s\n' "$line" >> "$SESSION_LOG" 2>/dev/null
    printf 'openconnect: %s\n' "$line"
    [ "$2" = 1 ] && [ -n "$LAUNCH_LOG" ] && printf '    %s\n' "$line" >> "$LAUNCH_LOG" 2>/dev/null
    [[ "$line" =~ $OC_KEY_RE ]] && printf '%s e=%s OC s=%s msg=%s\n' "$t" "$e" "$1" "$line" >> "$EVENTS" 2>/dev/null
  done
  return 0
}

sup_launch_oc() {
  SESSION_N=$((SESSION_N+1)); : > "$SESSION_LOG"
  local first=0; [ "$EVER_UP" = 0 ] && first=1
  # The password is handed to openconnect only via stdin; $! is the last process of the pipeline (openconnect itself; ip netns exec execs into it)
  printf '%s\n' "$VPN_PASS" | "${OC_PREFIX[@]}" "${OC_ARGS[@]}" > >(oc_log_pipe "$SESSION_N" "$first") 2>&1 &
  OC_PID=$!; OC_START=$(now_s)
  echo "$OC_PID" > "$PID_FILE"
}

sup_tunnel_up() {
  case "${CFG[MODE]}" in
    netns)   "$IP_CMD" -n "$NETNS_NAME" route show default 2>/dev/null | _gq 'dev tun' && "$IP_CMD" -n "$NETNS_NAME" link show 2>/dev/null | _gq 'tun.*UP' ;;
    default) "$IP_CMD" link show dev "$OC_TUN_DEFAULT" 2>/dev/null | _gq 'UP' ;;
    ocproxy) ss -Hlnt "sport = :${CFG[SOCKS_PORT]}" 2>/dev/null | _gq . ;;
  esac
}

sup_write_state() {
  local vps; vps=$(grep -E '^VPS[46]=' "$STATE_FILE" 2>/dev/null || true)
  {
    [ -n "$vps" ] && printf '%s\n' "$vps"
    echo "MODE=${CFG[MODE]}"; echo "ACCOUNT_INDEX=$(( CFG[ACCOUNT] - 1 ))"; echo "VPN_PROTOCOL=$(sup_proto)"
    if [ "${CFG[MODE]}" != default ]; then
      echo "SOCKS_PORT=${CFG[SOCKS_PORT]}"
      if [ "${CFG[MODE]}" = netns ]; then echo "LISTEN_ADDR=${CFG[LISTEN]}"; else echo "LISTEN_ADDR=127.0.0.1"; fi
    fi
    if [ "${CFG[MODE]}" = netns ]; then
      echo "GOST_PID=${GOST_PID:-}"; echo "FORWARDER=${_FWD_DESC:-}"
      [ -n "${CFG[SOCKS_USER]}" ] && printf 'SOCKS_USER=%q\nSOCKS_PASS=%q\n' "${CFG[SOCKS_USER]}" "${CFG[SOCKS_PASS]}"
      [ -n "${_FWD_STATE:-}" ] && printf '%s\n' "$_FWD_STATE"
    fi
    echo "KILL_SWITCH=${CFG[KILL_SWITCH]}"
  } > "$STATE_FILE.tmp"
  chmod 600 "$STATE_FILE.tmp"; mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

# SOCKS5 inside netns (gost) + host forwarding: started once the tunnel first comes up, then left untouched during reconnects
sup_start_proxy() {
  local port="${CFG[SOCKS_PORT]}" gl="socks5://:${CFG[SOCKS_PORT]}"
  [ -n "${CFG[SOCKS_USER]}" ] && gl="socks5://${CFG[SOCKS_USER]}:${CFG[SOCKS_PASS]}@:${port}"
  # socks5://:PORT without a host listens on both IPv4/IPv6 (0.0.0.0 listens on IPv4 only)
  "$IP_CMD" netns exec "$NETNS_NAME" gost -L="$gl" >/dev/null 2>&1 &
  GOST_PID=$!; echo "$GOST_PID" > "$GOST_PID_FILE"
  sleep 1; kill -0 "$GOST_PID" 2>/dev/null || { sup_log "gost failed to start in netns"; return 1; }
  if [ -z "${_FWD_DESC:-}" ]; then
    _FWD_DESC=""; _FWD_STATE=""
    _fwd_setup "${CFG[FORWARDER]}" "$port" "${CFG[LISTEN]}" >/dev/null || { sup_log "Port forwarding (${CFG[FORWARDER]}) setup failed"; return 1; }
  fi
  sup_write_state
  sup_log "SOCKS5 ready: ${CFG[LISTEN]}:${port} (gost pid $GOST_PID, forwarder ${_FWD_DESC})"
  return 0
}
# Restart gost / socat in place if they exit unexpectedly
sup_check_children() {
  [ "${CFG[MODE]}" = netns ] || return 0
  if [ -n "$GOST_PID" ] && ! kill -0 "$GOST_PID" 2>/dev/null; then
    ev "SUP child-died gost pid=$GOST_PID → restart"; sup_log "gost exited, restarting"; sup_start_proxy || true
  fi
  if [ "${_FWD_DESC:-}" = socat ]; then
    local sp; sp=$(cat "$SOCAT_PID_FILE" 2>/dev/null || true)
    if [[ "$sp" =~ ^[0-9]+$ ]] && ! kill -0 "$sp" 2>/dev/null; then
      ev "SUP child-died socat pid=$sp → restart"; sup_log "socat exited, reconfiguring forwarding"
      _FWD_STATE=""; _fwd_setup socat "${CFG[SOCKS_PORT]}" "${CFG[LISTEN]}" >/dev/null && sup_write_state
    fi
  fi
  [ "${CFG[DNS_FAST]}" = on ] && dns_fast_apply
  return 0
}

# DNS fast retry (netns only): vpnc-script rewrites resolv.conf on every connect, so add the line again after each connect
dns_fast_apply() {
  local f="/etc/netns/${NETNS_NAME}/resolv.conf"
  [ -f "$f" ] && grep -q 'VPNC_GENERATED' "$f" 2>/dev/null || return 0
  grep -q '^options .*timeout:1' "$f" 2>/dev/null || { printf 'options timeout:1 attempts:3 rotate\n' >> "$f"; ev "SUP dns-fast applied"; }
  return 0
}

# Kill switch (netns only): inside netns only the tunnel is allowed; the VPN gateway itself and veth replies are exceptions
ks_apply() {
  local NSX=("$IP_CMD" netns exec "$NETNS_NAME")
  GW_IP=$(getent ahostsv4 "$GW_NAME" 2>/dev/null | awk 'NR==1{print $1}')
  [ -n "$GW_IP" ] || { sup_log "Kill switch: cannot resolve gateway $GW_NAME"; return 1; }
  "${NSX[@]}" iptables -w -A OUTPUT -o lo -j ACCEPT &&
  "${NSX[@]}" iptables -w -A OUTPUT -o tun+ -j ACCEPT &&
  "${NSX[@]}" iptables -w -A OUTPUT -o "$VETH_NS" -d "$VETH_SUBNET" -j ACCEPT &&
  "${NSX[@]}" iptables -w -A OUTPUT -d "$GW_IP" -j ACCEPT &&
  "${NSX[@]}" iptables -w -A OUTPUT -j REJECT || { sup_log "Kill switch: failed to write iptables rules inside netns"; return 1; }
  if command -v ip6tables >/dev/null 2>&1; then
    "${NSX[@]}" ip6tables -w -A OUTPUT -o lo -j ACCEPT 2>/dev/null
    "${NSX[@]}" ip6tables -w -A OUTPUT -o tun+ -j ACCEPT 2>/dev/null
    "${NSX[@]}" ip6tables -w -A OUTPUT -j REJECT 2>/dev/null
  fi
  sup_log "Kill switch enabled (gateway $GW_NAME → $GW_IP)"
  return 0
}

# Restore the network baseline before reconnecting. When openconnect is kill -9'd / crashes, the vpnc-script disconnect never runs:
# the netns default route still points at the vanished tun and resolv.conf still holds the VPN's DNS, so the next connection cannot even resolve the gateway name
# (measured: reconnect after kill -9 reports getaddrinfo failed). On a normal exit vpnc-script restores them itself; this is an idempotent backup.
sup_reset_net() {
  case "${CFG[MODE]}" in
    netns)
      "$IP_CMD" -n "$NETNS_NAME" route show default 2>/dev/null | _gq "via ${VETH_HOST_IP}" \
        || { "$IP_CMD" -n "$NETNS_NAME" route replace default via "$VETH_HOST_IP" dev "$VETH_NS" 2>/dev/null && ev "SUP net-reset netns default route"; }
      local rf="/etc/netns/${NETNS_NAME}/resolv.conf"
      if grep -q 'VPNC_GENERATED' "$rf" 2>/dev/null; then
        { [ -r /etc/resolv.conf ] && cp /etc/resolv.conf "$rf"; } || echo "nameserver 8.8.8.8" > "$rf"
        ev "SUP net-reset netns resolv.conf"
      fi ;;
    default)
      if [ -n "${ORIG_DEF4:-}" ] && ! "$IP_CMD" -4 route show default 2>/dev/null | _gq .; then
        # shellcheck disable=SC2086
        "$IP_CMD" route replace $ORIG_DEF4 2>/dev/null && ev "SUP net-reset host default route"
      fi ;;
  esac
  return 0
}

# Decide why openconnect exited from the exit code and this run's output
# (openconnect source main.c: 2=cookie/auth rejected, 1=server terminated or network error, 0=received SIGTERM/SIGHUP)
sup_classify() {
  local rc="$1" up="$2" req=0
  [ -f "$RESTART_REQ" ] && { req=1; rm -f "$RESTART_REQ"; }
  # First check what openconnect itself said (server termination takes precedence over the soft reconnect flag, so a stale flag is not misread)
  if grep -qiE 'Server terminated connection|Session terminated by server|session expired|session timed out' "$SESSION_LOG" 2>/dev/null; then echo server-terminated; return; fi
  if [ $req = 1 ]; then echo watch-request; return; fi
  if [ "$rc" = 2 ] || grep -qiE 'login failed|authentication failed|invalid (user|pass|cred)|incorrect (user|pass)|password (has )?expired|account (is )?(locked|disabled)|cookie was rejected|failed to authenticate' "$SESSION_LOG" 2>/dev/null; then echo auth; return; fi
  if grep -qiE 'frmConfirmation|already (logged|signed) in|maximum number of (open )?(sessions|users)|session limit' "$SESSION_LOG" 2>/dev/null; then echo session-confirm; return; fi
  if [ "$up" = 0 ] && [ "$(grep -c frmLogin "$SESSION_LOG" 2>/dev/null)" -ge 4 ]; then echo auth; return; fi
  echo network
}

# sleep that can be interrupted by SIGTERM
sup_sleep() { local n="$1"; while [ "$n" -gt 0 ] && [ "$SUP_STOP" = 0 ]; do sleep 1 & wait $! 2>/dev/null; n=$((n-1)); done; }

sup_on_up() {
  local first=0 took=$(( $(now_s) - OC_START )); [ "$EVER_UP" = 0 ] && first=1
  EVER_UP=1
  if [ "${CFG[MODE]}" = netns ]; then
    [ "${CFG[DNS_FAST]}" = on ] && dns_fast_apply
    if [ $first = 1 ] || ! kill -0 "${GOST_PID:-0}" 2>/dev/null; then
      sup_start_proxy || { ev "SUP proxy-failed"; SUP_STOP=1; PAUSED_REASON="failed:proxy"; return 1; }
    fi
  fi
  set_phase up
  ev "SUP up session=$SESSION_N took=${took}s pid=$OC_PID"
  sup_log "Tunnel is up (connection #$SESSION_N, took ${took}s)"
  return 0
}

_supervise() {
  check_root
  set +e   # in the supervisor loop a single failed probe must not make the whole supervisor exit
  mkdir -p "$RUN_DIR" "$LOG_DIR" "$LAUNCH_DIR"; chmod 700 "$RUN_DIR" 2>/dev/null; chmod 750 "$LOG_DIR" 2>/dev/null
  settings_load; _load_kv_file "$RUN_PROFILE"
  LAUNCH_LOG=$(sed -n 's/^#LAUNCH_LOG=//p' "$RUN_PROFILE" 2>/dev/null | head -n1)
  [ -n "$LAUNCH_LOG" ] || LAUNCH_LOG="$LAUNCH_DIR/$(date +%Y%m%d-%H%M%S)-autostart.log"
  live_reload
  trap 'SUP_STOP=1' TERM INT HUP
  set_phase starting
  ev "SUP start v$VERSION mode=${CFG[MODE]} account=${CFG[ACCOUNT]} channel=${CFG[DATA_CHANNEL]} port=${CFG[SOCKS_PORT]} kill_switch=${CFG[KILL_SWITCH]}"

  # Clean up leftovers from the last abnormal exit (crash, kill -9, power loss) first, otherwise ports/netns conflict
  if [ -f "$STATE_FILE" ] || is_vpn_running || [ -e "/run/netns/$NETNS_NAME" ]; then
    sup_log "Found leftovers from the previous session, cleaning up first"; _teardown_session >/dev/null 2>&1
  fi
  GOST_PID=""; _FWD_DESC=""; _FWD_STATE=""   # cleanup sourced the old state; avoid reusing old values
  if ! account_load "${CFG[ACCOUNT]}"; then set_phase failed:account; ev "SUP fail reason=account"; exit 3; fi
  GW_NAME=$(gw_host_of "${CFG[ACCOUNT]}")
  sup_log "Account: ${VPN_DESC} (protocol $(sup_proto))  Mode: ${CFG[MODE]}  Data channel: ${CFG[DATA_CHANNEL]}"

  case "${CFG[MODE]}" in
    netns)
      if [ "${CFG[IPV6_FORWARD]}" = on ]; then OCM_IPV6_FORWARD=1; else OCM_IPV6_FORWARD=0; fi
      setup_netns >/dev/null || { set_phase failed:netns; ev "SUP fail reason=netns"; _teardown_session >/dev/null 2>&1; exit 3; }
      sup_log "Netns ${NETNS_NAME} is ready"
      if [ "${CFG[KILL_SWITCH]}" = on ]; then ks_apply || { set_phase failed:kill-switch; _teardown_session >/dev/null 2>&1; exit 3; }; fi ;;
    default)
      ORIG_DEF4=$("$IP_CMD" -4 route show default 2>/dev/null | grep -v ' dev tun\| dev ocmtun' | head -n1)
      setup_ssh_protect_routes >/dev/null || { set_phase failed:routes; ev "SUP fail reason=ssh-protect-routes"; _teardown_session >/dev/null 2>&1; exit 3; }
      sup_log "SSH protection routes configured" ;;
    ocproxy) : ;;
  esac
  _FWD_DESC=""; _FWD_STATE=""
  sup_write_state
  sup_build_oc

  local fails=0 authfails=0 rc kind age delay idx up t0 interval
  local -a attempts=() B=()
  while [ "$SUP_STOP" = 0 ]; do
    live_reload
    read -r -a B <<<"${LIVE[BACKOFF]}"; [ ${#B[@]} -gt 0 ] || B=(30)
    if [ "$EVER_UP" = 1 ]; then set_phase reconnecting; else set_phase connecting; fi
    attempts+=("$(now_s)")
    [ "$SESSION_N" -gt 0 ] && sup_reset_net
    sup_launch_oc
    sup_log "Starting openconnect (attempt #$SESSION_N, pid $OC_PID)"
    up=0; t0=$(now_s)
    while kill -0 "$OC_PID" 2>/dev/null && [ "$SUP_STOP" = 0 ]; do
      if [ $up = 0 ]; then
        if sup_tunnel_up; then up=1; sup_on_up || break
        elif [ $(( $(now_s) - t0 )) -ge 75 ]; then sup_log "Tunnel not up within 75 seconds, ending this attempt"; kill -TERM "$OC_PID" 2>/dev/null; fi
        interval=1
      else
        sup_check_children; interval=3
      fi
      sleep "$interval" & wait $! 2>/dev/null
    done
    [ "$SUP_STOP" = 1 ] && break
    wait "$OC_PID" 2>/dev/null; rc=$?
    [ "$SUP_STOP" = 1 ] && break
    set_phase reconnecting   # reflect the disconnect immediately; do not keep showing up during the seconds spent classifying the cause
    rm -f "$PID_FILE"
    sleep 1   # let the log pipe finish writing openconnect's last lines before classifying the exit reason
    age=$(( $(now_s) - OC_START )); kind=$(sup_classify "$rc" "$up")
    ev "SUP exit session=$SESSION_N rc=$rc kind=$kind session_age=$age session_age_h=$(fmt_dur $age) was_up=$up"
    sup_log "openconnect exited (rc=$rc, reason: $kind, session lasted $(fmt_dur $age))"
    tail -n 4 "$SESSION_LOG" 2>/dev/null | while IFS= read -r l; do ev "OCLAST $l"; done

    case "$kind" in
      server-terminated|watch-request) delay=2; fails=0 ;;
      auth) authfails=$((authfails+1)); fails=$((fails+1)) ;;
      *) fails=$((fails+1)) ;;
    esac
    [ "$up" = 1 ] && [ "$kind" != auth ] && authfails=0
    if [ "$kind" != server-terminated ] && [ "$kind" != watch-request ]; then
      idx=$((fails-1)); [ $idx -ge ${#B[@]} ] && idx=$(( ${#B[@]} - 1 )); [ $idx -lt 0 ] && idx=0; delay=${B[$idx]}
    fi

    if [ "${LIVE[AUTO_RECONNECT]}" != on ]; then sup_log "Auto reconnect is off, stopping"; ev "SUP no-reconnect (AUTO_RECONNECT=off)"; PAUSED_REASON="stopped:no-reconnect"; break; fi
    if [ "$kind" = auth ] && { [ "$EVER_UP" = 0 ] || [ "$authfails" -ge "${LIVE[AUTH_FAIL_PAUSE]}" ]; }; then
      sup_log "Auth failed ($authfails times in a row); stopped to avoid locking the account. Check the username/password, then start again."
      ev "SUP paused reason=auth authfails=$authfails"; PAUSED_REASON="failed:auth"; break
    fi
    # Hourly limit
    local -a recent=(); local t
    for t in "${attempts[@]}"; do [ $(( $(now_s) - t )) -lt 3600 ] && recent+=("$t"); done
    attempts=("${recent[@]}")
    if [ "${#attempts[@]}" -ge "${LIVE[MAX_PER_HOUR]}" ]; then
      local w=$(( attempts[0] + 3600 - $(now_s) )); [ $w -lt $delay ] || delay=$w
      ev "SUP rate-limited attempts_last_hour=${#attempts[@]} wait=${delay}s"; sup_log "Reconnected ${#attempts[@]} times within 1 hour, waiting ${delay}s"
    fi
    ev "SUP retry kind=$kind delay=${delay}s fails=$fails"
    sup_log "Reconnecting in ${delay}s"
    set_phase reconnecting
    sup_sleep "$delay"
  done

  # --- Stop: let openconnect log out first, then tear down proxy and network ---
  set_phase stopping
  if [ -n "$OC_PID" ] && kill -0 "$OC_PID" 2>/dev/null; then
    sup_log "Logging out openconnect..."; kill -TERM "$OC_PID" 2>/dev/null; _wait_pid_gone "$OC_PID"
  fi
  _teardown_session >/dev/null 2>&1
  rm -f "$RESTART_REQ" "$PID_FILE"
  ev "SUP stop reason=${PAUSED_REASON:-requested} sessions=$SESSION_N"
  set_phase "${PAUSED_REASON:-stopped}"
  sup_log "Stopped (${PAUSED_REASON:-requested})"
  exit 0
}

# ============================================================================
#  Start / stop (front end)
# ============================================================================
declare -A OVR=()     # temporary overrides from the command line or [this run only]
OPT_SAVE=0

show_summary() {
  local k
  title "📋 Settings for this start"
  for k in ACCOUNT MODE PROTOCOL DATA_CHANNEL; do printf '    %-14s %s\n' "${SET_TITLE[$k]}" "$(cfg_label "$k")"; done
  local acc_proto; acc_proto=$(account_field "${CFG[ACCOUNT]}" 6 2>/dev/null || true)
  [ -n "$acc_proto" ] && printf '    %-14s %s\n' "" "(the account has its own protocol ${acc_proto}, which overrides the line above)"
  case "${CFG[MODE]}" in
    netns) for k in SOCKS_PORT LISTEN SOCKS_AUTH FORWARDER KILL_SWITCH DNS_FAST; do printf '    %-14s %s\n' "${SET_TITLE[$k]}" "$(cfg_label "$k")"; done ;;
    ocproxy) printf '    %-14s %s\n' "${SET_TITLE[SOCKS_PORT]}" "127.0.0.1:${CFG[SOCKS_PORT]}" ;;
  esac
  printf '    %-14s %s\n' "${SET_TITLE[AUTO_RECONNECT]}" "$(cfg_label AUTO_RECONNECT)"
  [ "${CFG[MTU]}" != auto ] && printf '    %-14s %s\n' "MTU" "${CFG[MTU]}"
  [ -n "${CFG[OC_EXTRA]}" ] && printf '    %-14s %s\n' "Extra args" "${CFG[OC_EXTRA]}"
  return 0
}

start_preflight() {
  local n; n=$(accounts_count)
  [ "${n:-0}" -gt 0 ] || { log_err "No VPN account yet; add one first via the [Manage VPN accounts] menu."; return 1; }
  settings_validate ACCOUNT "${CFG[ACCOUNT]}" || return 1
  ensure_pkg_openconnect
  case "${CFG[MODE]}" in
    netns)
      ensure_pkg_iptables
      ensure_cmd_gost || return 1
      if [ "${CFG[FORWARDER]}" = socat ]; then ensure_cmd_socat || return 1; fi
      _check_port_free "${CFG[SOCKS_PORT]}" || { log_err "Port ${CFG[SOCKS_PORT]} is already in use; pick another (Settings -> SOCKS5 port)."; return 1; }
      [ "${CFG[LISTEN]}" = 0.0.0.0 ] && [ -z "${CFG[SOCKS_USER]}" ] && log_warn "SOCKS5 is open on all interfaces without authentication - anyone can use your proxy. Setting up authentication is recommended."
      ;;
    ocproxy)
      ensure_pkg_ocproxy
      _check_port_free "${CFG[SOCKS_PORT]}" || { log_err "Port ${CFG[SOCKS_PORT]} is already in use."; return 1; } ;;
    default) check_atd ;;
  esac
  return 0
}

run_profile_write() {
  local k
  mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"
  ( umask 077
    { printf '#LAUNCH_LOG=%s\n' "$LAUNCH_LOG"
      for k in "${SET_KEYS[@]}" SOCKS_USER SOCKS_PASS; do [ "$k" = SOCKS_AUTH ] && continue; printf '%s=%q\n' "$k" "${CFG[$k]:-}"; done
    } > "$RUN_PROFILE" )
}

# Merge OVR into CFG (already validated during parsing)
apply_overrides() { local k; for k in "${!OVR[@]}"; do CFG[$k]=${OVR[$k]}; done; }

# Interactive confirmation: start directly / change settings / this run only / cancel
start_confirm() {
  local a
  while true; do
    echo; show_summary; sep
    read -rp "Enter=start   s=change and save settings   t=this run only   q=cancel : " a || { echo; return 1; }
    case "$a" in
      "") return 0 ;;
      s|S) settings_menu; settings_load; apply_overrides ;;
      t|T) settings_menu ovr; apply_overrides ;;
      q|Q) log_info "Cancelled"; return 1 ;;
    esac
  done
}

cmd_start() { # $1=1 interactive confirmation
  local interactive="${1:-0}" rc=0
  check_root
  if svc_active; then log_err "VPN is already running (phase: $(get_phase)). To change settings use ocm restart."; return 3; fi
  if is_vpn_running; then log_err "Found an openconnect not managed by systemd (pid $(cat "$PID_FILE" 2>/dev/null), possibly started by an old version). Run ocm stop first to clean up."; return 3; fi
  settings_load; apply_overrides
  if [ "$interactive" = 1 ]; then start_confirm || return 1; fi
  start_preflight || return 1
  if [ "$OPT_SAVE" = 1 ]; then settings_save; log "Saved this run's settings as the defaults."; fi
  mkdir -p "$LAUNCH_DIR"
  LAUNCH_LOG="$LAUNCH_DIR/$(date +%Y%m%d-%H%M%S)-start.log"; : > "$LAUNCH_LOG"; chmod 640 "$LAUNCH_LOG"
  run_profile_write
  install_units || return 1
  rm -f "$PHASE_FILE" "$RESTART_REQ"
  ev "MARK ocm start mode=${CFG[MODE]} account=${CFG[ACCOUNT]} channel=${CFG[DATA_CHANNEL]} port=${CFG[SOCKS_PORT]} by=${SUDO_USER:-$(id -un)}"

  # Default global mode: fallback rollback (if broken routes cut off SSH, stop automatically after 3 minutes)
  local job="none"
  if [ "${CFG[MODE]}" = default ]; then
    job=$(echo "$SCRIPT_PATH stop" | at now + 3 minutes 2>&1 | awk '/job/{print $2}' || true)
    [[ "${job:-}" =~ ^[0-9]+$ ]] || job="none"
    if [ "$job" != none ]; then log_warn "Fallback job scheduled (at Job $job): stops automatically unless success is confirmed within 3 minutes."; else log_warn "Could not schedule the fallback job (at/atd unavailable)."; fi
  fi

  log_info "Handing over to systemd to start (${SVC_MAIN})..."
  systemctl reset-failed "$SVC_MAIN" >/dev/null 2>&1 || true
  systemctl start "$SVC_MAIN" || { log_err "systemctl start failed: journalctl -u $SVC_MAIN -n 50"; return 1; }
  start_follow || rc=$?
  sep
  case $rc in
    0) [ "$job" != none ] && atrm "$job" 2>/dev/null && log "Connection is stable, fallback job cancelled"
       start_result; return 0 ;;
    2) log_warn "Not connected within ${START_TIMEOUT} seconds; still retrying with backoff in the background. Check: ocm status / ocm log tail; give up: ocm stop"
       [ "$job" != none ] && atrm "$job" 2>/dev/null; return 1 ;;
    *) log_err "Start failed ($(get_phase)). Full output: $LAUNCH_LOG"
       [ "$job" != none ] && atrm "$job" 2>/dev/null; return 1 ;;
  esac
}

# Follow the launch log until up / failed / timeout
start_follow() {
  local off=0 t0 ph sz
  t0=$(now_s)
  while :; do
    sz=$(stat -c%s "$LAUNCH_LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$off" ]; then tail -c +$((off+1)) "$LAUNCH_LOG" | head -c $((sz-off)); off=$sz; fi
    ph=$(get_phase)
    case "$ph" in up) return 0;; failed:*|stopped*) return 1;; esac
    if ! svc_active && [ $(( $(now_s) - t0 )) -gt 5 ]; then return 1; fi
    [ $(( $(now_s) - t0 )) -ge "$START_TIMEOUT" ] && return 2
    sleep 1
  done
}

start_result() {
  local proxy code eg
  case "${CFG[MODE]}" in
    netns|ocproxy)
      proxy="socks5h://127.0.0.1:${CFG[SOCKS_PORT]}"
      [ "${CFG[MODE]}" = netns ] && [ -n "${CFG[SOCKS_USER]}" ] && proxy="socks5h://${CFG[SOCKS_USER]}:${CFG[SOCKS_PASS]}@127.0.0.1:${CFG[SOCKS_PORT]}"
      code=$("$CURL_CMD" -s -o /dev/null -w '%{http_code}' --max-time 10 -x "$proxy" http://www.gstatic.com/generate_204 2>/dev/null || true)
      eg=$(_pub_ip -4 "$proxy" 2>/dev/null || echo "lookup failed")
      log "VPN connected: SOCKS5 ${CFG[LISTEN]}:${CFG[SOCKS_PORT]}  probe ${code:-none}  VPN egress ${eg}"
      [ "${CFG[LISTEN]}" = 127.0.0.1 ] && log_info "To use from your own computer: ssh -N -L ${CFG[SOCKS_PORT]}:127.0.0.1:${CFG[SOCKS_PORT]} <your-VPS>, then set the browser proxy to SOCKS5 127.0.0.1:${CFG[SOCKS_PORT]}"
      ;;
    default) log "VPN connected (global mode), host egress: $(_pub_ip -4 2>/dev/null || echo lookup-failed)" ;;
  esac
  ev "MARK ocm start result=ok egress=${eg:-?}"
}

cmd_stop() {
  check_root
  ev "MARK ocm stop: manual stop by=${SUDO_USER:-$(id -un)}"
  if svc_active || [ "$(get_phase)" = reconnecting ]; then
    log_info "Stopping (openconnect logout may take a few seconds)..."
    systemctl stop "$SVC_MAIN" 2>/dev/null || true
  fi
  # Fallback: sessions started by old (unmanaged) versions or abnormal leftovers
  if is_vpn_running || [ -f "$STATE_FILE" ] || [ -f "$GOST_PID_FILE" ] || [ -f "$SOCAT_PID_FILE" ] || [ -e "/run/netns/$NETNS_NAME" ]; then
    _teardown_session
  fi
  rm -f "$RESTART_REQ"
  log "VPN stopped."
}
stop_vpn() { cmd_stop; }   # compatibility with the old call name (uninstall flow etc.)

# ============================================================================
#  Diagnostic log (ocm-watch.service -> `ocm _watch`)
# ----------------------------------------------------------------------------
#  Read-only sampling: never starts/stops the VPN, never touches routes/iptables/sysctl; the only "action" is, when openconnect is still alive
#  but the proxy keeps failing (DEGRADED >= DEGRADED_WAIT) or the egress falls back to the host (FALLBACK >= 20s), to write
#  restart-request and TERM openconnect, leaving the reconnect to the supervisor.
#  Files (${LOG_DIR}):
#    samples.log      one line of objective metrics every SAMPLE_INTERVAL seconds (tightened to 5 seconds for 3 minutes after a state change)
#    events.log       changes only: STATUS transitions, CHANGE field changes, SUP (supervisor), OC (openconnect key lines), MARK
#    openconnect.log  all openconnect output (written by the supervisor)
#    incidents/       a snapshot every time UP is left / an abnormal state is entered
#    launch/          full launch output of every ocm start
#  All rotated by size and gzipped, total capped by LOG_MAX_MB; sampling pauses when the partition has < 400MB free.
# ============================================================================
INTERVAL=30; FAST_INTERVAL=5; FAST_WINDOW=180; IDLE_INTERVAL=120; WATCH_STEP=5
STARTUP_GRACE=90; BAD_CONFIRM=2
PROBE_URL=http://www.gstatic.com/generate_204; EXTRA_PROBE_URL=""
TUN_PING_TARGET=1.1.1.1; EGRESS_EVERY=10; HOST_EGRESS_TTL=1800; HEARTBEAT_EVERY=21600
ROTATE_BYTES=2097152; KEEP_SAMPLES=150; KEEP_EVENTS=60; KEEP_OCLOG=60; KEEP_INCIDENTS=400
MAX_TOTAL_MB=300; MIN_FREE_MB=400
NAT_SUBNET="$VETH_SUBNET"
# Session timeline: when the session age crosses these seconds a SESSION milestone is logged; the [FROM,TO] range forces 5-second sampling;
# the report marks non-manual session ends falling in [LO,HI] as "~2h" (many school/company VPNs have a fixed session length)
AGE_MARKS="3600 6600 7080 7200 7320 7800 10800"
AGE_WATCH_FROM=7080; AGE_WATCH_TO=7500; AGE_SUSPECT_LO=6900; AGE_SUSPECT_HI=7500
LAST_KICK=0

now_ts() { printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1; }
ms_now() { local n; n=$(date +%s%N); echo $(( n / 1000000 )); }
watch_dirs() { mkdir -p "$LOG_DIR" "$INC_DIR" "$LAUNCH_DIR" "$WATCH_LIB" 2>/dev/null; chmod 750 "$LOG_DIR" 2>/dev/null || true; }
watch_reload_cfg() {
  settings_load
  [[ "${CFG[SAMPLE_INTERVAL]}" =~ ^[0-9]+$ ]] && [ "${CFG[SAMPLE_INTERVAL]}" -ge 5 ] && INTERVAL=${CFG[SAMPLE_INTERVAL]}
  [[ "${CFG[LOG_MAX_MB]}" =~ ^[0-9]+$ ]] && MAX_TOTAL_MB=${CFG[LOG_MAX_MB]}
  EXTRA_PROBE_URL=${CFG[EXTRA_PROBE_URL]}
  return 0
}
_watch() {
  check_root
  set +e
  watch_reload_cfg
  _watch_loop
}

# ---------------- Status ----------------
cmd_status() {
  local verbose="${1:-}" ph since st wsince rest
  [ "$EUID" -eq 0 ] || { log_err "Please run as root"; return 1; }
  settings_load
  title "== OpenConnect Master v${VERSION} =="
  ph=$(get_phase); since=$(get_phase_since)
  printf 'VPN service : %s' "$(systemctl is-active "$SVC_MAIN" 2>/dev/null || true)"
  [ -n "$ph" ] && printf '   phase %s (%s)' "$ph" "$( [[ "$since" =~ ^[0-9]+$ ]] && fmt_dur $(( $(now_s) - since )) || echo ?)"
  local en; en=$(systemctl is-enabled "$SVC_MAIN" 2>/dev/null || true)
  printf '   autostart %s\n' "${en:-not installed}"
  printf 'Diag log    : %s   auto reconnect %s\n' "$(systemctl is-active "$SVC_WATCH" 2>/dev/null || true)" "$(cfg_label AUTO_RECONNECT)"
  if [ -f "$STATE_FILE" ]; then
    local MODE="" ACCOUNT_INDEX="" VPN_PROTOCOL="" SOCKS_PORT="" LISTEN_ADDR="" FORWARDER="" SOCKS_USER="" SOCKS_PASS="" KILL_SWITCH=""
    # shellcheck disable=SC1090
    . "$STATE_FILE" 2>/dev/null || true
    printf 'Session     : account %s  mode %s  protocol %s' "$(account_field $(( ${ACCOUNT_INDEX:-0} + 1 )) 1 2>/dev/null || echo '?')" "${MODE:-?}" "${VPN_PROTOCOL:-?}"
    [ -n "$SOCKS_PORT" ] && printf '  SOCKS5 %s:%s%s' "${LISTEN_ADDR:-127.0.0.1}" "$SOCKS_PORT" "${SOCKS_USER:+ (auth ${SOCKS_USER}:****)}"
    [ -n "$FORWARDER" ] && printf '  forwarder %s' "$FORWARDER"
    echo
    is_vpn_running && printf 'openconnect: pid %s, running for %s\n' "$(cat "$PID_FILE")" "$(fmt_dur "$(ps -o etimes= -p "$(cat "$PID_FILE")" 2>/dev/null | tr -d ' ')")"
  else
    echo "Session     : none"
  fi
  if [ -r "$WATCH_LIB/current" ]; then
    read -r st wsince rest < "$WATCH_LIB/current"
    printf 'Diag verdict: %s (for %s)\n' "$st" "$(fmt_dur $(( $(now_s) - wsince )))"
    local eg; eg=$(grep -o ' eg=[0-9.]*' "$SAMPLES" 2>/dev/null | tail -n1 | cut -d= -f2 || true)
    [ -n "$eg" ] && printf 'Last egress : %s\n' "$eg"
    [ "$verbose" = -v ] && printf 'Last sample : %s\n' "$rest"
  fi
  printf 'Log dir     : %s (%s)\n' "$LOG_DIR" "$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)"
  echo "Recent events:"
  grep -aE ' (STATUS|SUP|WATCH restart|MARK|RECOVERED) ' "$EVENTS" 2>/dev/null | grep -v ' HEARTBEAT ' | tail -n "$([ "$verbose" = -v ] && echo 25 || echo 8)" | cut -c1-200 | sed 's/^/  /' || true
  return 0
}

cmd_log() {
  local sub="${1:-report}"; shift || true
  case "$sub" in
    report)   cmd_report "${1:-7}" ;;
    tail)     exec tail -n 40 -F "$EVENTS" "$OCLOG" ;;
    snapshot) check_root; watch_dirs; settings_load; read_state; local f; f=$(snapshot "${1:-manual}"); ev "INCIDENT saved $f (manual)"; echo "$f" ;;
    mark)     check_root; [ $# -gt 0 ] || { log_err "Usage: ocm log mark <text>"; return 2; }; ev "MARK $*"; echo "Recorded" ;;
    dir)      echo "$LOG_DIR" ;;
    *) log_err "Unknown subcommand: log $sub (available: report|tail|snapshot|mark|dir)"; return 2 ;;
  esac
}

rotate_file() { # file  copies-to-keep
  local f="$1" keep="$2" sz dst
  sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
  [ "$sz" -ge "$ROTATE_BYTES" ] || return 0
  dst="$f.$(printf '%(%Y%m%d-%H%M%S)T' -1)"
  mv -f "$f" "$dst" 2>/dev/null || return 0
  nice -n 19 gzip -f "$dst" 2>/dev/null || true
  ls -1 "$f".*.gz 2>/dev/null | sort | head -n -"$keep" | xargs -r rm -f
}

# Disk protection: partition free space + directory total cap
LOW_DISK=0
disk_guard() {
  local free used
  free=$(df -Pm "$LOG_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  if [[ "${free:-}" =~ ^[0-9]+$ ]] && [ "$free" -lt "$MIN_FREE_MB" ]; then
    [ "$LOW_DISK" = 0 ] && ev "DISK low free=${free}MB min=${MIN_FREE_MB}MB -> pausing samples writes"
    LOW_DISK=1
  else
    [ "$LOW_DISK" = 1 ] && ev "DISK ok free=${free:-?}MB -> resuming samples writes"
    LOW_DISK=0
  fi
  used=$(du -sm "$LOG_DIR" 2>/dev/null | awk '{print $1}')
  local guard=0
  while [[ "${used:-0}" =~ ^[0-9]+$ ]] && [ "$used" -gt "$MAX_TOTAL_MB" ] && [ $guard -lt 50 ]; do
    local victim
    victim=$(ls -1tr "$SAMPLES".*.gz "$OCLOG".*.gz 2>/dev/null | head -n1)
    [ -z "$victim" ] && victim=$(ls -1tr "$INC_DIR"/* 2>/dev/null | head -n1)
    [ -z "$victim" ] && break
    rm -f "$victim"; guard=$((guard+1))
    used=$(du -sm "$LOG_DIR" 2>/dev/null | awk '{print $1}')
  done
  [ $guard -gt 0 ] && ev "DISK cap ${MAX_TOTAL_MB}MB exceeded, deleted ${guard} oldest rotated files"
  return 0
}

gw_host() { # gateway host of the account used by the current session (the settings account if there is no session)
  local idx
  idx=$(grep -a '^ACCOUNT_INDEX=' "$STATE_FILE" 2>/dev/null | cut -d= -f2)
  if [[ "$idx" =~ ^[0-9]+$ ]]; then idx=$((idx+1)); else idx=${CFG[ACCOUNT]:-1}; fi
  gw_host_of "$idx"
}

# ping parsing: prints "loss%/avg_ms"
ping_stat() { # raw ping -q output
  local out="$1" loss rtt
  loss=$(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' <<<"$out" | head -n1)
  rtt=$(sed -n 's/.*= [0-9.]*\/\([0-9.]*\)\/.*/\1/p' <<<"$out" | head -n1)
  printf '%s%%/%sms' "${loss:-?}" "${rtt:--}"
}

# ---------------- Read ocm state ----------------
read_state() {
  ST_HAVE=0; ST_MODE=""; ST_PROTO=""; ST_PORT=""; ST_FWD=""; ST_USER=""; ST_PASS=""; ST_LISTEN=""
  [ -r "$STATE_FILE" ] || return 0
  ST_HAVE=1
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      MODE) ST_MODE=$v ;; VPN_PROTOCOL) ST_PROTO=$v ;; SOCKS_PORT) ST_PORT=$v ;;
      FORWARDER) ST_FWD=$v ;; LISTEN_ADDR) ST_LISTEN=$v ;;
    esac
  done < <(grep -aE '^(MODE|VPN_PROTOCOL|SOCKS_PORT|FORWARDER|LISTEN_ADDR)=' "$STATE_FILE" 2>/dev/null)
  if grep -aq '^SOCKS_USER=' "$STATE_FILE" 2>/dev/null; then
    # Values are %q-escaped and ocm itself sources this file; source it in a subshell and take only these two
    ST_USER=$( . "$STATE_FILE" >/dev/null 2>&1; printf '%s' "${SOCKS_USER:-}" )
    ST_PASS=$( . "$STATE_FILE" >/dev/null 2>&1; printf '%s' "${SOCKS_PASS:-}" )
  fi
  [[ "$ST_PORT" =~ ^[0-9]+$ ]] || ST_PORT=""
}

# ---------------- Sampling ----------------
declare -A PREV=()
TICK=0
OC_START=0; OC_START_PID=""; S_SESS="-"
HOST_EG="-"; HOST_EG_AT=0
LAST_SOCKS_EG="-"; FALLBACK=0
BAD_STREAK=0
GW_HOST=""

# Take one sample: sets the S_* variables plus LINE, CAND (candidate state), REASON
sample() {
  TICK=$((TICK+1))
  S_TS=$(now_ts); S_E=$(now_s)
  read_state

  # --- openconnect process ---
  S_OCPID="-"; S_OCAGE="-"
  local p; p=$(cat "$PID_FILE" 2>/dev/null || true)
  if [[ "$p" =~ ^[0-9]+$ ]] && [ "$(cat /proc/$p/comm 2>/dev/null)" = openconnect ]; then
    S_OCPID=$p; S_OCAGE=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')
  fi
  # Remember the session start (~auth time): so "how long the session had lasted at disconnect" can still be computed after the process exits
  if [ "$S_OCPID" != "-" ] && [[ "$S_OCAGE" =~ ^[0-9]+$ ]]; then OC_START=$((S_E - S_OCAGE)); OC_START_PID=$S_OCPID; fi
  if [ "${OC_START:-0}" -gt 0 ]; then S_SESS=$((S_E - OC_START)); else S_SESS="-"; fi
  S_OCN=$(pgrep -c -x openconnect 2>/dev/null || true); S_OCN=${S_OCN:-0}
  S_GOST=$(pgrep -c -x gost 2>/dev/null || true); S_GOST=${S_GOST:-0}
  S_SOCAT=$(pgrep -c -x socat 2>/dev/null || true); S_SOCAT=${S_SOCAT:-0}

  # --- Tunnel interface (in the namespace for netns mode, on the host for default mode) ---
  local IPN=(ip); S_NS=0 want_tun=1
  if [ -e "/run/netns/$NETNS_NAME" ]; then S_NS=1; fi
  if [ "$ST_MODE" = netns ] || { [ -z "$ST_MODE" ] && [ $S_NS = 1 ]; }; then IPN=(ip -n "$NETNS_NAME"); fi
  # ocproxy creates no kernel tun; tuns of other programs on the host (overlay networks etc.) must not count as the VPN's
  case "$ST_MODE" in ocproxy|"") [ $S_NS = 1 ] || want_tun=0 ;; esac
  S_TUN="-"; S_TUNST="-"; S_TUNIP="-"; S_RX="-"; S_TX="-"; S_DEFTUN=0
  if [ $want_tun = 1 ] && { [ "${IPN[1]:-}" != "-n" ] || [ $S_NS = 1 ]; }; then
    local links; links=$(timeout 3 "${IPN[@]}" -o link show 2>/dev/null)
    if [ "$ST_MODE" = default ]; then S_TUN=$(grep -o "$OC_TUN_DEFAULT" <<<"$links" | head -n1)
    else S_TUN=$(grep -o 'tun[0-9]\+' <<<"$links" | head -n1); fi
    S_TUN=${S_TUN:--}
    if [ "$S_TUN" != "-" ]; then
      if grep -m1 " $S_TUN:" <<<"$links" | grep -q 'LOWER_UP'; then S_TUNST=UP; else S_TUNST=DOWN; fi
      S_TUNIP=$(timeout 3 "${IPN[@]}" -4 -o addr show dev "$S_TUN" 2>/dev/null | awk '{print $4; exit}'); S_TUNIP=${S_TUNIP:--}
      local rx tx
      read -r rx tx < <(timeout 3 "${IPN[@]}" -s link show dev "$S_TUN" 2>/dev/null | awk '/RX:/{getline; r=$1} /TX:/{getline; t=$1} END{print r+0, t+0}')
      if [[ "${rx:-}" =~ ^[0-9]+$ ]] && [[ "${PREV[rx]:-}" =~ ^[0-9]+$ ]] && [ "$rx" -ge "${PREV[rx]}" ]; then
        S_RX="+$((rx - PREV[rx]))"; S_TX="+$((tx - PREV[tx]))"
      else S_RX="new"; S_TX="new"; fi
      PREV[rx]=${rx:-}; PREV[tx]=${tx:-}
    else
      PREV[rx]=""; PREV[tx]=""
    fi
    timeout 3 "${IPN[@]}" route show default 2>/dev/null | grep -q 'dev tun' && S_DEFTUN=1
  fi

  # --- SOCKS availability (one real HTTP request through the proxy) ---
  S_LISTEN="-"; S_SOCKS="-"; S_SOCKSMS="-"; S_XPROBE="-"
  local proxy=""
  if [ -n "$ST_PORT" ]; then
    S_LISTEN=$(ss -Hlnt "sport = :$ST_PORT" 2>/dev/null | wc -l)
    local auth=""; [ -n "$ST_USER" ] && auth="${ST_USER}:${ST_PASS}@"
    proxy="socks5h://${auth}127.0.0.1:${ST_PORT}"
    local out
    out=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout 5 --max-time 10 -x "$proxy" "$PROBE_URL" 2>/dev/null)
    S_SOCKS=${out%% *}; S_SOCKS=${S_SOCKS:-000}
    S_SOCKSMS=$(awk -v t="${out##* }" 'BEGIN{printf "%d", t*1000}')
    if [ -n "$EXTRA_PROBE_URL" ]; then
      S_XPROBE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 -x "$proxy" "$EXTRA_PROBE_URL" 2>/dev/null); S_XPROBE=${S_XPROBE:-000}
    fi
  fi

  # --- Ping inside the tunnel (the netns default route goes via tun) ---
  S_TPING="-"
  if [ "$S_OCPID" != "-" ] && [ $S_NS = 1 ] && [ "$ST_MODE" = netns ]; then
    S_TPING=$(ping_stat "$(timeout 6 ip netns exec "$NETNS_NAME" ping -n -q -c 3 -i 0.3 -w 4 "$TUN_PING_TARGET" 2>/dev/null)")
  fi

  # --- Host side: DNS / TCP handshake / ping to the VPN gateway, the host's own internet access ---
  { [ -z "$GW_HOST" ] || [ $((TICK % 120)) -eq 0 ]; } && GW_HOST=$(gw_host)
  S_GWIP="-"; S_GWTCP="-"; S_GWPING="-"; S_HPING="-"
  if [ -n "$GW_HOST" ]; then
    S_GWIP=$(timeout 4 getent ahostsv4 "$GW_HOST" 2>/dev/null | awk 'NR==1{print $1}'); S_GWIP=${S_GWIP:-DNSFAIL}
    if [ "$S_GWIP" != DNSFAIL ]; then
      local a b; a=$(ms_now)
      if timeout 4 bash -c ">/dev/tcp/$S_GWIP/443" 2>/dev/null; then b=$(ms_now); S_GWTCP="$((b-a))ms"; else S_GWTCP=FAIL; fi
      S_GWPING=$(ping_stat "$(ping -n -q -c 3 -i 0.3 -w 4 "$S_GWIP" 2>/dev/null)")
    fi
  fi
  S_HPING=$(ping_stat "$(ping -n -q -c 2 -i 0.3 -w 3 1.1.1.1 2>/dev/null)")

  # --- netns egress dependencies: MASQUERADE rule, ip_forward, veth ---
  S_NAT=$(timeout 4 iptables -w 2 -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-s $NAT_SUBNET")
  S_FWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "?")
  S_VETH=0; ip link show veth_ocm_h >/dev/null 2>&1 && S_VETH=1

  # --- TCP retransmit/timeout deltas inside netns (actual quality of proxy traffic) ---
  S_RETR="-"; S_TMO="-"
  if [ $S_NS = 1 ]; then
    local r t
    read -r r t < <(timeout 4 ip netns exec "$NETNS_NAME" nstat -asz 2>/dev/null | awk '$1=="TcpRetransSegs"{r=$2} $1=="TcpExtTCPTimeouts"{t=$2} END{print r+0, t+0}')
    if [[ "${PREV[retr]:-}" =~ ^[0-9]+$ ]] && [ "${r:-0}" -ge "${PREV[retr]}" ]; then
      S_RETR="+$((r - PREV[retr]))"; S_TMO="+$((t - PREV[tmo]))"
    fi
    PREV[retr]=${r:-0}; PREV[tmo]=${t:-0}
  else PREV[retr]=""; PREV[tmo]=""; fi

  S_MEM=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)

  # --- Egress IP (low frequency): egress via SOCKS vs host egress; identical = the proxy is not going through the VPN ---
  S_EG="-"; S_NSDNS="-"
  if [ -n "$proxy" ] && { [ $((TICK % EGRESS_EVERY)) -eq 1 ] || [ "${FORCE_EGRESS:-0}" = 1 ]; }; then
    if [ "$HOST_EG" = "-" ] || [ $((S_E - HOST_EG_AT)) -ge "$HOST_EGRESS_TTL" ]; then
      local h; h=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)
      [ -z "$h" ] && h=$(curl -4 -s --max-time 6 https://ifconfig.me/ip 2>/dev/null || true)
      if [[ "$h" =~ ^[0-9.]+$ ]]; then HOST_EG=$h; HOST_EG_AT=$S_E; fi
    fi
    S_EG=$(curl -4 -s --connect-timeout 5 --max-time 10 -x "$proxy" https://api.ipify.org 2>/dev/null || true)
    [[ "$S_EG" =~ ^[0-9.]+$ ]] || S_EG="FAIL"
    if [ "$S_EG" != FAIL ]; then
      LAST_SOCKS_EG=$S_EG
      if [ "$HOST_EG" != "-" ] && [ "$S_EG" = "$HOST_EG" ]; then FALLBACK=1; else FALLBACK=0; fi
    fi
    if [ $S_NS = 1 ]; then
      if timeout 5 ip netns exec "$NETNS_NAME" getent ahostsv4 www.gstatic.com >/dev/null 2>&1; then S_NSDNS=ok; else S_NSDNS=FAIL; fi
    fi
  fi
  [ -z "$proxy" ] && FALLBACK=0

  # --- Decide the candidate state ---
  REASON=""
  if [ "$ST_HAVE" = 0 ]; then
    if [ "$S_OCN" -gt 0 ]; then
      # ocm's netns start flow writes state only at the very end: a freshly started openconnect counts as STARTING first
      local young; young=$(ps -o etimes= -p "$(pgrep -n -x openconnect)" 2>/dev/null | tr -d ' ')
      if [[ "$young" =~ ^[0-9]+$ ]] && [ "$young" -lt "$STARTUP_GRACE" ]; then
        CAND=STARTING; REASON="openconnect-up-${young}s-waiting-for-ocm-state"
      else
        CAND=UNMANAGED; REASON="openconnect-running-without-ocm-state"
      fi
    else CAND=STOPPED; fi
  elif [ "$S_OCPID" = "-" ]; then
    CAND=DOWN; REASON="openconnect-gone(state-file-still-present)"
  else
    local pr=""
    if [ "$ST_MODE" = netns ]; then
      [ $S_NS = 1 ] || pr="${pr}netns-missing,"
      [ "$S_TUN" = "-" ] && pr="${pr}tun-missing,"
      [ "$S_TUN" != "-" ] && [ "$S_TUNST" != UP ] && pr="${pr}tun-down,"
      [ $S_DEFTUN = 1 ] || pr="${pr}no-default-via-tun,"
      [ "$S_NAT" -ge 1 ] 2>/dev/null || pr="${pr}masquerade-missing,"
      [ "$S_FWD" = 1 ] || pr="${pr}ip_forward-off,"
    fi
    if [ -n "$ST_PORT" ]; then
      [ "$S_LISTEN" -ge 1 ] 2>/dev/null || pr="${pr}socks-not-listening,"
      [[ "$S_SOCKS" =~ ^[23] ]] || pr="${pr}socks-probe-fail(${S_SOCKS}),"
    fi
    if [ -n "$pr" ]; then
      REASON=${pr%,}
      if [[ "$S_OCAGE" =~ ^[0-9]+$ ]] && [ "$S_OCAGE" -lt "$STARTUP_GRACE" ]; then CAND=STARTING; else CAND=DEGRADED; fi
    elif [ "$FALLBACK" = 1 ]; then
      CAND=FALLBACK; REASON="socks-egress==host-egress(${HOST_EG})"
    else
      CAND=UP
    fi
  fi

  LINE=$(printf '%s st=%s mode=%s proto=%s oc=%s age=%s sess=%s ocn=%s gost=%s socat=%s tun=%s/%s ip=%s deftun=%s rx=%s tx=%s listen=%s socks=%s/%sms xprobe=%s tping=%s gw=%s gwtcp=%s gwping=%s hping=%s nat=%s fwd=%s veth=%s retr=%s tmo=%s eg=%s nsdns=%s mem=%sMB%s' \
    "$S_TS" "$CAND" "${ST_MODE:--}" "${ST_PROTO:--}" "$S_OCPID" "$S_OCAGE" "$S_SESS" "$S_OCN" "$S_GOST" "$S_SOCAT" \
    "$S_TUN" "$S_TUNST" "$S_TUNIP" "$S_DEFTUN" "$S_RX" "$S_TX" "$S_LISTEN" "$S_SOCKS" "$S_SOCKSMS" "$S_XPROBE" \
    "$S_TPING" "$S_GWIP" "$S_GWTCP" "$S_GWPING" "$S_HPING" "$S_NAT" "$S_FWD" "$S_VETH" "$S_RETR" "$S_TMO" \
    "$S_EG" "$S_NSDNS" "$S_MEM" "$([ -n "$REASON" ] && printf ' why=%s' "$REASON")")
}

# ---------------- Incident snapshot ----------------
LAST_SNAP=0
snapshot() { # tag
  local tag="${1:-manual}" f
  watch_dirs
  f="$INC_DIR/$(printf '%(%Y%m%d-%H%M%S)T' -1)-${tag//[^A-Za-z0-9_.-]/_}.txt"
  {
    sec() { printf '\n===== %s =====\n' "$1"; }
    printf 'oc-master %s incident snapshot  tag=%s  time=%s  host=%s\n' "$VERSION" "$tag" "$(now_ts)" "$(hostname)"
    sec "Last 12 samples"; tail -n 12 "$SAMPLES" 2>/dev/null
    sec "Last 15 events"; tail -n 15 "$EVENTS" 2>/dev/null
    sec "openconnect output (last 150 lines)"; tail -n 150 "$OCLOG" 2>/dev/null
    sec "supervisor phase / service status"; cat "$PHASE_FILE" 2>/dev/null; systemctl --no-pager --lines=0 status "$SVC_MAIN" 2>/dev/null | head -n 6
    sec "ocm state file (redacted)"; sed -E 's/^(SOCKS_PASS)=.*/\1=<redacted>/' "$STATE_FILE" 2>/dev/null || echo "(does not exist)"
    sec "Related processes"; ps -eo pid,ppid,etimes,stat,rss,args 2>/dev/null | grep -E 'openconnect|gost|socat|ocproxy|oc_master|ocm' | grep -v grep
    sec "at queue (ocm fallback stop job)"; atq 2>/dev/null
    sec "netns: link/addr/route"
    timeout 4 ip -n "$NETNS_NAME" -s link 2>/dev/null; timeout 4 ip -n "$NETNS_NAME" addr 2>/dev/null; timeout 4 ip -n "$NETNS_NAME" route 2>/dev/null
    sec "netns: resolv.conf / TCP summary"
    cat "/etc/netns/$NETNS_NAME/resolv.conf" 2>/dev/null; timeout 4 ip netns exec "$NETNS_NAME" ss -s 2>/dev/null
    timeout 4 ip netns exec "$NETNS_NAME" ss -tnp 2>/dev/null | head -n 40
    sec "Host: ip rule / route / veth"
    ip rule 2>/dev/null; ip route 2>/dev/null; ip -s link show veth_ocm_h 2>/dev/null
    sec "Host: iptables nat (netns/port related)"
    timeout 5 iptables -w 2 -t nat -S 2>/dev/null | grep -E "192\.168\.200|MASQUERADE|${ST_PORT:-8585}" 
    sec "Host: sysctl"
    sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding "net.ipv4.conf.veth_ocm_h.route_localnet" 2>/dev/null
    sec "Host: listening ports"; ss -lntp 2>/dev/null | grep -E ":${ST_PORT:-8585}\b" 
    sec "Connectivity re-test"
    local gw; gw=$(gw_host)
    echo "gw_host=$gw"; timeout 4 getent ahostsv4 "$gw" 2>/dev/null | head -n 3
    ping -n -c 4 -i 0.3 -w 5 "$gw" 2>&1 | tail -n 3
    timeout 8 curl -s -o /dev/null -w 'gw https: code=%{http_code} connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s\n' "https://$gw/" 2>&1
    ping -n -c 3 -w 4 1.1.1.1 2>&1 | tail -n 2
    timeout 6 ip netns exec "$NETNS_NAME" ping -n -c 3 -w 4 "$TUN_PING_TARGET" 2>&1 | tail -n 2
    timeout 6 ip netns exec "$NETNS_NAME" getent ahostsv4 www.gstatic.com 2>&1 | head -n 2
    [ -n "${ST_PORT:-}" ] && curl -s -o /dev/null -w "socks probe: code=%{http_code} total=%{time_total}s\n" --max-time 10 -x "socks5h://127.0.0.1:${ST_PORT}" "$PROBE_URL" 2>&1
    sec "Memory / OOM / kernel messages (last 30 minutes)"
    free -m; ps -eo pid,rss,comm --sort=-rss | head -n 8
    timeout 10 journalctl -k --since "-30min" --no-pager -o short-iso 2>/dev/null | tail -n 60
    sec "System logs at warning and above (last 15 minutes)"
    timeout 15 journalctl -p warning --since "-15min" --no-pager -o short-iso 2>/dev/null | grep -vE 'ocm-sentinel' | tail -n 60 | redact
    sec "TCP counters (host)"; nstat -asz 2>/dev/null | grep -E 'TcpRetransSegs|TCPTimeouts|TCPAbortOn|TcpExtListenDrops' 
  } > "$f" 2>&1
  chmod 640 "$f" 2>/dev/null || true
  ls -1 "$INC_DIR"/*.txt 2>/dev/null | sort | head -n -"$KEEP_INCIDENTS" | xargs -r rm -f
  printf '%s' "$f"
}

# ---------------- Main loop ----------------
_watch_loop() {
  watch_dirs
  trap 'ev "WATCH stop pid=$$ (signal)"; exit 0' TERM INT
  ev "WATCH start v$VERSION pid=$$ interval=${INTERVAL}s fast=${FAST_INTERVAL}s/${FAST_WINDOW}s probe=$PROBE_URL"

  local status="" since=0 fast_until=0 last_hb=0 t0 dt nap now bad_start=0 bad_since=0 bad_from=""
  status="INIT"; since=$(now_s); last_hb=$since
  FORCE_EGRESS=1
  while :; do
    t0=$(now_s)
    sample
    FORCE_EGRESS=0
    now=$S_E

    # --- Session timeline milestones: log one when the session age crosses AGE_MARKS (within the same openconnect process) ---
    if [ "$S_OCPID" != "-" ] && [[ "$S_OCAGE" =~ ^[0-9]+$ ]]; then
      local pa=${PREV[ocage]:-} m
      if [ "${PREV[ocagepid]:-}" = "$S_OCPID" ] && [[ "$pa" =~ ^[0-9]+$ ]]; then
        for m in $AGE_MARKS; do
          if [ "$pa" -lt "$m" ] && [ "$S_OCAGE" -ge "$m" ]; then
            ev "SESSION age_mark=$(fmt_dur $m) age=$S_OCAGE pid=$S_OCPID status=$status cand=$CAND socks=$S_SOCKS/${S_SOCKSMS}ms tping=$S_TPING rx=$S_RX tx=$S_TX started=$(date -d "@$OC_START" '+%F %T')"
          fi
        done
      fi
      PREV[ocage]=$S_OCAGE; PREV[ocagepid]=$S_OCPID
    fi

    # --- Field change events (no need to wait for a state transition) ---
    local chg="" k v
    for k in OCPID:"$S_OCPID" TUNIP:"$S_TUNIP" GWIP:"$S_GWIP" NAT:"$S_NAT" FWD:"$S_FWD" VETH:"$S_VETH" MODE:"${ST_MODE:--}" PROTO:"${ST_PROTO:--}"; do
      v=${k#*:}; k=${k%%:*}
      if [ -n "${PREV[$k]+x}" ] && [ "${PREV[$k]}" != "$v" ]; then chg="${chg} ${k}:${PREV[$k]}->${v}"; fi
      PREV[$k]=$v
    done
    if [ "$S_EG" != "-" ] && [ "$S_EG" != FAIL ]; then
      [ -n "${PREV[EG]+x}" ] && [ "${PREV[EG]}" != "$S_EG" ] && chg="${chg} EGRESS:${PREV[EG]}->${S_EG}"
      PREV[EG]=$S_EG
    fi
    # Gateway reachability flips are logged separately too (to tell "school gateway down/route broken" from "local problem")
    local gwok=1; [ "$S_GWTCP" = FAIL ] && gwok=0; [ "$S_GWIP" = DNSFAIL ] && gwok=0
    [ -n "${PREV[GWOK]+x}" ] && [ "${PREV[GWOK]}" != "$gwok" ] && chg="${chg} GW_REACH:${PREV[GWOK]}->${gwok}(tcp=${S_GWTCP},ping=${S_GWPING})"
    PREV[GWOK]=$gwok
    [ -n "$chg" ] && ev "CHANGE${chg}"

    # --- State transitions (UP->DEGRADED needs consecutive confirmation, others take effect immediately) ---
    local new=$CAND
    # Trouble in a session that has already been UP is a "runtime anomaly"; it must not be classed as STARTING just because the process is young
    [ "$new" = STARTING ] && [ "$status" = UP ] && [ "$ST_HAVE" = 1 ] && new=DEGRADED
    if [ "$new" = DEGRADED ] && [ "$status" = UP ]; then
      BAD_STREAK=$((BAD_STREAK+1))
      if [ $BAD_STREAK -lt "$BAD_CONFIRM" ]; then
        new=UP
        fast_until=$((now + FAST_WINDOW))
        ev "WARN single anomaly pending confirmation (${BAD_STREAK}/${BAD_CONFIRM}): ${REASON}"
        [ $BAD_STREAK -eq 1 ] && bad_start=$now
      fi
    else
      [ "$new" = UP ] && BAD_STREAK=0
    fi

    if [ "$new" != "$status" ]; then
      local held=$((now - since)) heal=0
      # State changes while the supervisor is reconnecting do not count as a manual stop
      case "$(get_phase)" in reconnecting|connecting) heal=1;; esac
      ev "STATUS from=$status to=$new heal=$heal held=$held held_h=$(fmt_dur $held) session_age=$S_SESS session_age_h=$(fmt_dur "$S_SESS") session_pid=${OC_START_PID:--} reason=${REASON:-ok} oc=$S_OCPID tun=$S_TUN/$S_TUNST socks=$S_SOCKS gwtcp=$S_GWTCP"
      case "$new" in
        DOWN|DEGRADED|FALLBACK|UNMANAGED)
          fast_until=$((now + FAST_WINDOW)); FORCE_EGRESS=1
          # Put openconnect's last few lines straight into the events, so the cause is visible at a glance without digging through files
          tail -n 6 "$OCLOG" 2>/dev/null | while IFS= read -r l; do ev "OCLAST $l"; done
          ;;
      esac
      # Outage timing: counted from "first entering an abnormal state"; transitional states like STARTING in between do not interrupt it
      if [[ "$new" =~ ^(DOWN|DEGRADED|FALLBACK|UNMANAGED)$ ]] && [ "$bad_since" = 0 ]; then bad_since=$now; bad_from=$status; fi
      if [ "$new" = UP ] && [ "$bad_since" != 0 ]; then
        ev "RECOVERED outage=$((now - bad_since)) outage_h=$(fmt_dur $((now - bad_since))) (since leaving $bad_from)"
        bad_since=0
      fi
      [ "$new" = STOPPED ] && { [ "$heal" = 1 ] || bad_since=0; OC_START=0; OC_START_PID=""; }
      # Leaving UP or entering an abnormal state: save a snapshot (in the background so sampling is not slowed; at most one per minute, except DOWN)
      if { [ "$status" = UP ] || [[ "$new" =~ ^(DOWN|DEGRADED|FALLBACK|UNMANAGED)$ ]]; } && [ "$status" != INIT ]; then
        if [ "$new" = DOWN ] || [ $((now - LAST_SNAP)) -ge 60 ]; then
          LAST_SNAP=$now
          ( sleep 2; f=$(snapshot "${status}-to-${new}"); ev "INCIDENT saved $f" ) &
        fi
      fi
      status=$new; since=$now
    fi

    # --- Soft reconnect: openconnect is still alive, but the proxy keeps failing / egress fell back to the host ---
    if [ "${CFG[AUTO_RECONNECT]}" = on ] && [ "$S_OCPID" != "-" ] && [ "$(get_phase)" = up ] && svc_active; then
      local want=""
      [ "$status" = DEGRADED ] && [ $((now - since)) -ge "${CFG[DEGRADED_WAIT]}" ] && want="degraded-$((now - since))s:${REASON}"
      [ "$status" = FALLBACK ] && [ $((now - since)) -ge 20 ] && want="fallback:${REASON}"
      if [ -n "$want" ] && [ $((now - LAST_KICK)) -ge 120 ]; then
        LAST_KICK=$now; touch "$RESTART_REQ"; kill -TERM "$S_OCPID" 2>/dev/null
        ev "WATCH restart-request reason=$want pid=$S_OCPID"
      fi
    fi

    # --- Write sample ---
    [ "$LOW_DISK" = 0 ] && printf '%s\n' "$LINE" >> "$SAMPLES" 2>/dev/null
    printf '%s %s %s\n' "$status" "$since" "$LINE" > "$WATCH_LIB/current" 2>/dev/null

    # --- Heartbeat, rotation, disk, follow-up process care ---
    if [ $((now - last_hb)) -ge "$HEARTBEAT_EVERY" ]; then
      ev "HEARTBEAT status=$status for=$(fmt_dur $((now - since))) samples=$(stat -c%s "$SAMPLES" 2>/dev/null)B"
      last_hb=$now
    fi
    rotate_file "$SAMPLES" "$KEEP_SAMPLES"
    rotate_file "$EVENTS" "$KEEP_EVENTS"
    rotate_file "$OCLOG" "$KEEP_OCLOG"
    [ $((TICK % 10)) -eq 1 ] && disk_guard
    [ $((TICK % 20)) -eq 0 ] && watch_reload_cfg

    local inwin=0
    [[ "$S_OCAGE" =~ ^[0-9]+$ ]] && [ "$S_OCAGE" -ge "$AGE_WATCH_FROM" ] && [ "$S_OCAGE" -le "$AGE_WATCH_TO" ] && inwin=1
    if [ "$now" -lt "$fast_until" ] || [ $inwin = 1 ]; then nap=$FAST_INTERVAL
    elif [ "$status" = STOPPED ]; then nap=$IDLE_INTERVAL
    else nap=$INTERVAL; fi
    dt=$(( $(now_s) - t0 )); nap=$((nap - dt)); [ $nap -lt 1 ] && nap=1
    # Between two samples, every WATCH_STEP seconds do an ultra-light liveness check (no network requests):
    #   a session appearing/disappearing or the openconnect process exiting -> sample early right away, so the disconnect time is accurate to about 5 seconds.
    local end=$(( $(now_s) + nap )) left step
    while :; do
      left=$(( end - $(now_s) )); [ $left -le 0 ] && break
      step=$WATCH_STEP; [ $left -lt $step ] && step=$left
      sleep "$step" & wait $!
      if [ "$status" = STOPPED ]; then
        { [ -f "$STATE_FILE" ] || pgrep -x openconnect >/dev/null 2>&1; } && break
      else
        [ -f "$STATE_FILE" ] || break
        [ "$S_OCPID" != "-" ] && ! kill -0 "$S_OCPID" 2>/dev/null && break
        [ "$S_OCPID" = "-" ] && [ -r "$PID_FILE" ] && break
      fi
    done
  done
}

# ---------------- Report ----------------
cmd_report() {
  local days="${1:-7}"; [[ "$days" =~ ^[0-9]+$ ]] || days=7
  local cutoff=$(( $(now_s) - days*86400 ))
  echo "== ocm diagnostic report: last ${days} days (since $(date -d "@$cutoff" '+%F %T')) =="
  # Every segment needs || true: the foreground runs with set -e + pipefail, and without rotated files a failing ls would make the whole subshell exit early, skipping the cat
  { { ls -1 "$EVENTS".*.gz 2>/dev/null | sort | xargs -r zcat 2>/dev/null; } || true; cat "$EVENTS" 2>/dev/null || true; } \
  | awk -v cut="$cutoff" -v nowe="$(now_s)" -v slo="$AGE_SUSPECT_LO" -v shi="$AGE_SUSPECT_HI" '
    function kv(k,   i,a){ for(i=2;i<=NF;i++){ if(index($i,k"=")==1){ return substr($i,length(k)+2) } } return "" }
    function dur(s,  d,h,m){ d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); if(d>0) return sprintf("%dd%02dh%02dm",d,h,m); if(h>0) return sprintf("%dh%02dm",h,m); if(m>0) return sprintf("%dm%02ds",m,s%60); return sprintf("%ds",s) }
    { e=kv("e")+0 }
    $3=="STATUS" {
      from=kv("from"); to=kv("to"); held=kv("held")+0
      if (e>=cut) {
        st=(e-held<cut)? cut : e-held
        if (from!="INIT") tm[from]+= (e-st)
        # Consecutive abnormal states (DOWN->STARTING->DEGRADED...) are merged into one outage, with the reasons concatenated in order
        if (to ~ /^(DOWN|DEGRADED|FALLBACK|UNMANAGED)$/) {
          if (open>0) { why[open]=why[open] " ; " to ":" kv("reason") }
          else { n++; ts[n]=$1; fr[n]=from; tt[n]=to; why[n]=kv("reason"); hf[n]=held; be[n]=e; sa[n]=kv("session_age"); open=n }
        }
        if (to=="UP" && open>0) { rec[open]=e-be[open]; open=0 }
        if (to=="STOPPED" && open>0 && kv("heal")!="1") { rec[open]=-1; open=0 }
        # Session end timeline: how long the session had lasted at the moment it left UP (manual stops marked separately)
        # Only a real session end counts (process exit/egress fallback/stopped); DEGRADED is a brief in-session fault, counted separately
        if (from=="UP" && to=="DEGRADED") blips++
        if (from=="UP" && to!="UP" && to!="DEGRADED") {
          a=kv("session_age")
          if (a ~ /^[0-9]+$/) {
            se++; se_ts[se]=$1; se_to[se]=to; se_age[se]=a+0; se_why[se]=kv("reason")
            se_man[se]=(md>0 && e-md<=60) ? 1 : 0
            if (!se_man[se] && a+0>=slo && a+0<=shi) near2h++
            if (!se_man[se]) unplanned++
          }
        }
      }
      last_to=to; last_e=e
    }
    # State is unknown while the logger itself is down: on a normal stop, settle up to the stop time; on an abnormal exit (no stop line) do not count
    ($3=="SENTINEL" || $3=="WATCH") && $4=="stop" { if (last_to!="" && e>=cut) { st=(last_e<cut)?cut:last_e; if (last_to!="INIT") tm[last_to]+=e-st } ; last_to=""; last_e=0 }
    ($3=="SENTINEL" || $3=="WATCH") && $4=="start" { last_to=""; last_e=0 }
    $3=="OC" && e>=cut {
      m=tolower($0)
      if (m ~ /dead peer|dpd/) c["DPD/peer lost"]++
      if (m ~ /reconnect/) c["reconnect"]++
      if (m ~ /terminat|session.*(end|expir)|expired/) c["session ended/expired"]++
      if (m ~ /esp/) c["ESP related"]++
      if (m ~ /fail|error|refused|denied|unauthor/) c["fail/error"]++
      if (m ~ /cancel|sigint|sigterm/) c["manual/signal exit"]++
      if (m ~ /establish/) c["tunnel established"]++
    }
    $3=="SUP" && e>=cut {
      if ($4=="exit") { sx++; sk[kv("kind")]++ }
      if ($4=="up") sup++
      if ($4=="paused" || $4=="rate-limited") ahP++
      if ($4 ~ /^(exit|up|paused|rate-limited|start|stop|child-died|fail|no-reconnect)$/) { ah++; ahs[ah]=$0 }
      next
    }
    $3=="WATCH" && $4=="restart-request" && e>=cut { wr++; ah++; ahs[ah]=$0; next }
    $3=="MARK" && $4=="AUTOHEAL" && e>=cut {
      ah++; ahs[ah]=$0
      if ($5=="trigger") ahT++
      if ($5 ~ /^result=ok/) ahOK++
      if ($5 ~ /^result=FAIL/) ahF++
      if ($5=="paused:" || $5=="rate-limited:") ahP++
      next
    }
    $3=="MARK" && e>=cut {
      if ($0 ~ /\[autoheal\]/) next
      mk++; mks[mk]=$0; if ($0 ~ /ocm-nc down|ocm stop|TEST:/) md=e
    }
    $3=="SESSION" && e>=cut { sm++; sms[sm]=$0 }
    $3=="CHANGE" && e>=cut { ch++; chs[ch]=$0 }
    END {
      if (last_to!="" && last_e>0) { st=(last_e<cut)?cut:last_e; tm[last_to]+= nowe-st }
      tot=0; for (k in tm) if (k!="STOPPED") tot+=tm[k]
      printf "Current status: %s (for %s)\n", (last_to==""?"unknown":last_to), (last_e>0?dur(nowe-last_e):"-")
      printf "Time in state:"
      for (k in tm) printf " %s=%s", k, dur(tm[k])
      if (tot>0 && ("UP" in tm)) printf "  | availability (excluding STOPPED) %.2f%%", 100*tm["UP"]/tot
      printf "\n\nAnomalies/outages: %d\n", n
      for (i=1;i<=n;i++) printf "  %s  %s→%s  session age %-10s recovered in %-12s reason %s\n", ts[i], fr[i], tt[i], (sa[i] ~ /^[0-9]+$/ ? dur(sa[i]+0) : "?"), (i in rec ? (rec[i]<0?"stopped":dur(rec[i])) : "not recovered yet"), why[i]
      printf "\nSession end timeline (time since auth when leaving UP; ≈2h = %s–%s):\n", dur(slo), dur(shi)
      if (!se) print "  (no session end records yet)"
      for (i=1;i<=se;i++) printf "  %s  →%-9s session %-10s %s%s  %s\n", se_ts[i], se_to[i], dur(se_age[i]), (se_man[i]?"[manual] ":""), (!se_man[i] && se_age[i]>=slo && se_age[i]<=shi ? "[≈2h!] " : ""), se_why[i]
      if (unplanned>0) printf "  %d non-manual ends, %d of them in the ≈2h window\n", unplanned, near2h
      printf "  Brief in-session faults (DEGRADED, not disconnected): %d\n", blips
      printf "\nAuto reconnect: openconnect exited %d times", sx
      if (sx) { printf " ("; sep=""; for (k in sk) { printf "%s%s=%d", sep, k, sk[k]; sep=" " } printf ")" }
      printf ", back up %d times, soft reconnect requests %d, paused or rate-limited %d", sup, wr, ahP
      if (ahT) printf "; legacy autoheal triggered %d times (ok %d / failed %d)", ahT, ahOK, ahF
      printf " (last 15):\n"
      if (!ah) print "  (none)"
      for (i=(ah>15?ah-14:1); i<=ah; i++) print "  " ahs[i]
      printf "\nSession milestones (last 12 of %d):\n", sm
      for (i=(sm>12?sm-11:1); i<=sm; i++) print "  " sms[i]
      printf "\nopenconnect key message counts:\n"; nc=0
      for (k in c) { printf "  %-16s %d\n", k, c[k]; nc++ }
      if (!nc) print "  (none)"
      printf "\nField changes (last 15 of %d):\n", ch
      for (i=(ch>15?ch-14:1); i<=ch; i++) print "  " chs[i]
      printf "\nManual marks (last 10 of %d):\n", mk
      for (i=(mk>10?mk-9:1); i<=mk; i++) print "  " mks[i]
    }'
  echo
  echo "Recent incident snapshots:"; ls -1t "$INC_DIR"/*.txt 2>/dev/null | head -n 8 | sed 's/^/  /' || true
  echo
  echo "Dig deeper: grep -E 'STATUS|OC |CHANGE|INCIDENT' $EVENTS | tail -n 50"
  echo "            less $OCLOG    zcat -f $SAMPLES* | grep -v 'st=UP'"
}


# --- Scheduling & uninstall ---
# Keep a copy before writing crontab: the places below all use `... | crontab -`; if `crontab -l`
# returns empty for some reason (permissions, concurrent writes, command error), the whole crontab gets overwritten with nothing - on a production box that could
# be dozens of jobs. The backup is made only when crontab is non-empty, and failing to write it does not block what follows.
_CRON_BAK="/root/.oc_master-crontab.bak"
_backup_crontab() {
  local cur=""
  cur="$(crontab -l 2>/dev/null || true)"
  [ -n "$cur" ] || return 0
  # crontab often contains passwords/tokens: the backup file uses 600, not 644 from the default umask
  if ( umask 077; printf '%s\n' "$cur" > "$_CRON_BAK" ) 2>/dev/null; then
    log_info "Backed up the current crontab to ${_CRON_BAK}"
  else
    log_warn "Failed to back up crontab (${_CRON_BAK} not writable), continuing."
  fi
  return 0
}

# Ask before uninstalling a dependency. The key difference:
#   installed by this script      -> default Y (the user installed it for this script)
#   already on the machine        -> warning + default N, so we do not delete something used for other purposes
# Returns 0 = user confirmed removal.
_ask_uninstall_dep() {
  local name="$1" desc="$2" ans=""
  if _dep_installed_by_us "$name"; then
    read -rp "Uninstall $name? ($desc, installed by this script) [Y/n]: " ans || ans=""
    [[ "$ans" =~ ^[nN]$ ]] && { log_info "Kept $name."; return 1; }
    return 0
  fi
  log_warn "$name was not installed by this script (you may have installed it yourself, or it has other uses)."
  read -rp "Are you sure you want to uninstall $name? [y/N]: " ans || ans=""
  if [[ "$ans" =~ ^[yY]$ ]]; then return 0; fi
  log_info "Kept $name."
  return 1
}

uninstall() {
  local y=""
  read -rp "⚠️  Are you sure you want to uninstall this script and all related configuration? [y/N]: " y || y=""
  [[ "$y" =~ ^[yY]$ ]] || { log_info "Cancelled"; exit 0; }
  log_info "Starting uninstall..."; stop_vpn
  uninstall_units; log "systemd units removed"
  local yl=""; read -rp "Also delete settings and diagnostic logs (${CONF_DIR}, ${LOG_DIR})? [y/N]: " yl || yl=""
  if [[ "$yl" =~ ^[yY]$ ]]; then rm -rf "$CONF_DIR" "$LOG_DIR" "$WATCH_LIB" "$RUN_DIR"; log "Settings and logs deleted"; else log_info "Kept ${CONF_DIR} and ${LOG_DIR}"; fi
  _backup_crontab
  crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true; log "Scheduled tasks cleaned up"
  
  if command -v gost &>/dev/null; then
    if _ask_uninstall_dep gost "SOCKS5 server for Netns mode"; then
      # The official install.sh only knows the single --install argument and has no uninstall branch: passing --remove or similar
      # drops into the "choose a version" install menu (one interactive choice really reinstalls/upgrades it),
      # and when select fails non-interactively the old code still printed "uninstall attempted" - a lie.
      # gost is a single binary with no package manager record, so just delete the file.
      log_info "Uninstalling gost..."
      # Prefer stopping the one "started by this script" via the PID file: pkill -x gost matches the process name globally and would
      # also kill gost instances used for other purposes on the machine. So only when there is no PID record from this script and gost
      # really is still running do we ask, and let the user decide whether to kill all by name.
      local _gp=""
      if [ -f "$GOST_PID_FILE" ]; then
        _gp="$(cat "$GOST_PID_FILE" 2>/dev/null || echo "")"
        if [ -n "$_gp" ] && [ "$(cat /proc/${_gp}/comm 2>/dev/null)" = "gost" ]; then
          kill "$_gp" 2>/dev/null || true
        else
          _gp=""
        fi
      fi
      if [ -z "$_gp" ] && command -v pgrep &>/dev/null && pgrep -x gost >/dev/null 2>&1; then
        log_warn "Found a running gost process (not the one recorded by this script); it may be used for something else."
        local _gk=""
        read -rp "Kill all gost processes by name? [y/N]: " _gk || _gk=""
        [[ "$_gk" =~ ^[yY]$ ]] && { pkill -x gost 2>/dev/null || true; }
      fi
      rm -f "$(command -v gost 2>/dev/null)" 2>/dev/null || true
      if command -v gost &>/dev/null; then log_warn "Failed to uninstall gost, please delete it manually."
      else log "gost uninstalled."; fi
    fi
  fi
  
  if command -v socat &>/dev/null; then
    if _ask_uninstall_dep socat "port forwarding for Netns mode"; then
      if command -v apt-get &>/dev/null; then apt-get purge -y socat >/dev/null || true
      elif command -v yum &>/dev/null; then yum remove -y socat >/dev/null || true
      elif command -v dnf &>/dev/null; then dnf remove -y socat >/dev/null || true; fi
      if command -v socat &>/dev/null; then log_warn "Failed to uninstall socat, please remove it manually."
      else log "socat uninstalled."; fi
    fi
  fi

  log_warn "OpenConnect / ocproxy are common packages that other programs may also use; if unsure, choose N to keep them."
  read -rp "Uninstall the OpenConnect and ocproxy packages? [y/N]: " yn_oc || yn_oc=""
  if [[ "$yn_oc" =~ ^[yY]$ ]]; then
    if command -v apt-get &>/dev/null; then apt-get purge -y openconnect ocproxy >/dev/null || true
    elif command -v yum &>/dev/null; then yum remove -y openconnect ocproxy >/dev/null || true
    elif command -v dnf &>/dev/null; then dnf remove -y openconnect ocproxy >/dev/null || true; fi
    log "Attempted to uninstall OpenConnect/ocproxy."
  fi
  
  rm -f "$ACCOUNTS_FILE"; log "Accounts file deleted"
  # Old versions (the menu-10 era) may have left a forwarder preference file under /var/lib/oc-master; remove it too
  rm -f "$DEPS_MARK_FILE" "${DEPS_STATE_DIR}/forwarder"; rmdir "$DEPS_STATE_DIR" 2>/dev/null || true
  remove_shortcut
  log_info "Deleting script file: $SCRIPT_PATH"; rm -f "$SCRIPT_PATH"; log "Uninstall complete. Goodbye!"
}

# ============================================================================
#  Settings menu
# ----------------------------------------------------------------------------
#  target=cfg: change and save to settings.conf; target=ovr: this run only (the "t" before starting), not saved.
#  choice types are picked by number; common presets of int/text types are picked by letter, or a value can be typed directly.
# ============================================================================
_pause() { read -n1 -s -rp "${1:-Press any key to return...}" || true; echo; }

settings_edit_item() {
  local k="$1" target="${2:-cfg}" t="${SET_TYPE[$1]}" v="" a old j c
  local -a cs=()
  clear 2>/dev/null || true
  title "⚙️  ${SET_TITLE[$k]}   ${C_GREY}($k)${C_RESET}"; sep
  _set_help "$k"; sep
  echo -e "Current: ${C_CYAN}$(cfg_label "$k")${C_RESET}"
  [ -n "${SET_CHOICES[$k]}" ] && IFS=',' read -r -a cs <<<"${SET_CHOICES[$k]}"
  case "$t" in
    choice)
      j=0; for c in "${cs[@]}"; do j=$((j+1)); printf '  %d) %s  %s\n' "$j" "${c#*:}" "$(echo -e "${C_GREY}[${c%%:*}]${C_RESET}")"; done
      read -rp "Choose a number (Enter keeps the current value): " a || return 0
      [ -z "$a" ] && return 0
      [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le ${#cs[@]} ] || { log_err "Invalid number"; _pause; return 0; }
      v=${cs[$((a-1))]%%:*} ;;
    int|text)
      local letters=abcdefghij
      j=0; for c in "${cs[@]}"; do printf '  %s) %s  %s\n' "${letters:$j:1}" "${c#*:}" "$(echo -e "${C_GREY}[${c%%:*}]${C_RESET}")"; j=$((j+1)); done
      if [ "$t" = text ]; then read -rp "Pick a letter preset, type a new value, or - to clear (Enter keeps the current value): " a || return 0
      else read -rp "Pick a letter preset or type a number (Enter keeps the current value): " a || return 0; fi
      [ -z "$a" ] && return 0
      if [[ "$a" =~ ^[a-j]$ ]]; then
        j=$(( $(printf '%d' "'$a") - 97 )); [ $j -lt ${#cs[@]} ] || { log_err "Invalid preset"; _pause; return 0; }
        v=${cs[$j]%%:*}
      elif [ "$t" = text ] && [ "$a" = - ]; then v=""
      else v="$a"; fi ;;
    account)
      accounts_list
      read -rp "Choose an account number (Enter keeps the current value): " a || return 0
      [ -z "$a" ] && return 0
      v="$a" ;;
    auth)
      local u="" p="" yn=""
      read -rp "Enable SOCKS5 authentication? [y/N]: " yn || return 0
      if [[ "$yn" =~ ^[yY]$ ]]; then
        read -rp "  Username: " u || return 0
        settings_validate SOCKS_USER "$u" && [ -n "$u" ] || { log_err "Invalid username"; _pause; return 0; }
        read -rsp "  Password: " p || return 0; echo
        settings_validate SOCKS_PASS "$p" && [ -n "$p" ] || { log_err "Invalid password"; _pause; return 0; }
      fi
      CFG[SOCKS_USER]=$u; CFG[SOCKS_PASS]=$p
      if [ "$target" = ovr ]; then OVR[SOCKS_USER]=$u; OVR[SOCKS_PASS]=$p
      else settings_save; ev "CONFIG SOCKS_AUTH -> ${u:+on(user=$u)}${u:-off}"; fi
      log "Set: $(cfg_label SOCKS_AUTH)"; _settings_restart_note "$k" "$target"; _pause; return 0 ;;
  esac
  settings_validate "$k" "$v" || { _pause; return 0; }
  old=${CFG[$k]}; CFG[$k]=$v
  if [ "$target" = ovr ]; then
    OVR[$k]=$v; log "This run uses: $(cfg_label "$k")"
  else
    settings_save; ev "CONFIG $k: ${old} -> ${v}"; log "Saved: $(cfg_label "$k")"
    case "$k" in WATCH|AUTOSTART) apply_service_prefs ;; esac
  fi
  _settings_restart_note "$k" "$target"
  _pause
}
_settings_restart_note() {
  [ "$2" = cfg ] || return 0
  case "$SET_NEEDS_RESTART" in *" $1 "*) svc_active && log_warn "VPN is running: this change takes effect after a restart (menu 2 or ocm restart).";; esac
  return 0
}

settings_menu() {
  local target="${1:-cfg}" n i k g lastg mark
  while true; do
    clear 2>/dev/null || true
    if [ "$target" = ovr ]; then title "⏱  This run only (not saved, applies to this start only)"; else title "⚙️  Settings   ${C_GREY}${SETTINGS_FILE}${C_RESET}"; fi
    sep
    i=0; lastg=""
    for k in "${SET_KEYS[@]}"; do
      i=$((i+1)); g=${SET_GROUP[$k]}
      [ "$g" != "$lastg" ] && { echo -e "  ${C_GREY}── ${g} ──${C_RESET}"; lastg=$g; }
      mark=""; [ "$target" = ovr ] && [ -n "${OVR[$k]+x}" ] && mark=" ${C_YELLOW}(this run)${C_RESET}"
      echo -e "  $(printf '%2d' $i)) ${SET_TITLE[$k]}: ${C_CYAN}$(cfg_label "$k")${C_RESET}${mark}"
    done
    sep
    echo "  Pick a number to see its description and change it; 0 to go back"
    read -rp "Select: " n || return 0
    case "$n" in
      0|"") return 0 ;;
      *) [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#SET_KEYS[@]} ] || continue
         settings_edit_item "${SET_KEYS[$((n-1))]}" "$target" || true ;;
    esac
  done
}

# ============================================================================
#  Scheduled tasks (v8: automatic reconnect after disconnects is handled by the systemd supervisor; this only does scheduled start/stop)
# ============================================================================
manage_cron() {
  local c exp act cron_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if ! command -v crontab &>/dev/null; then
    clear 2>/dev/null || true; title "🗓️ Scheduled tasks"; sep
    log_err "cron/crontab is not installed; scheduled tasks are unavailable. You can first run: apt-get install -y cron"; sep; _pause "Press any key to return to the main menu..."; return 0
  fi
  while true; do
    clear 2>/dev/null || true; title "🗓️ Scheduled tasks"; sep
    crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH" || log_info "  No scheduled tasks for this script."
    crontab -l 2>/dev/null | grep -q "_internal_check_health" && log_warn "  Found a legacy guard job (_internal_check_health): v8 replaces it with systemd auto reconnect; choosing 3 to remove it is recommended."
    sep
    echo "  1) Add scheduled start (ocm start with the saved settings)"
    echo "  2) Add scheduled stop (ocm stop)"
    echo "  3) Remove all scheduled tasks for this script (including legacy guard jobs)"
    echo "  4) Back to main menu"
    read -rp "Please select [1-4]: " c || return 0
    case "$c" in
      1|2) act=start; [ "$c" = 2 ] && act=stop
           read -rp "cron expression (min hour day month weekday, e.g. '0 8 * * 1-5' = weekdays at 8:00): " exp || continue
           [ "$(wc -w <<<"$exp")" -eq 5 ] || { log_err "5 fields are required"; _pause; continue; }
           _backup_crontab
           { crontab -l 2>/dev/null || true; echo "$exp PATH=$cron_path $SCRIPT_PATH $act >/dev/null 2>&1"; } | crontab -
           log "Added: $exp → ocm $act"; _pause ;;
      3) _backup_crontab
         { crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" || true; } | crontab - 2>/dev/null || true
         log "Removed."; _pause ;;
      4) return 0 ;;
      *) log_err "Invalid option"; sleep 1 ;;
    esac
  done
}

# ============================================================================
#  Main menu status area (reads local state only, no network requests, so the menu opens instantly)
# ============================================================================
show_status() {
  sep
  local ph; ph=$(get_phase)
  if svc_active; then
    case "$ph" in
      up)           title "  VPN status: ${C_GREEN}🟢 Running${C_RESET}  ${C_GREY}(managed by systemd)${C_RESET}" ;;
      reconnecting) title "  VPN status: ${C_YELLOW}🟡 Reconnecting${C_RESET}" ;;
      *)            title "  VPN status: ${C_YELLOW}🟡 ${ph:-starting}${C_RESET}" ;;
    esac
    if [ -f "$STATE_FILE" ]; then
      local MODE="" ACCOUNT_INDEX="" VPN_PROTOCOL="" SOCKS_PORT="" LISTEN_ADDR="" FORWARDER="" SOCKS_USER="" SOCKS_PASS="" KILL_SWITCH=""
      # shellcheck disable=SC1090
      . "$STATE_FILE" 2>/dev/null || true
      echo -e "    ${C_BOLD}Account:${C_RESET} $(account_field $(( ${ACCOUNT_INDEX:-0} + 1 )) 1 2>/dev/null || echo '?')   ${C_BOLD}Mode:${C_RESET} ${MODE:-?}   ${C_BOLD}Protocol:${C_RESET} ${VPN_PROTOCOL:-?}"
      [ -n "$SOCKS_PORT" ] && echo -e "    ${C_BOLD}SOCKS5:${C_RESET} ${LISTEN_ADDR:-127.0.0.1}:${SOCKS_PORT}${SOCKS_USER:+ (auth ${SOCKS_USER}:****)}${FORWARDER:+ ${C_GREY}by ${FORWARDER}${C_RESET}}"
    fi
    if is_vpn_running; then
      echo -e "    ${C_BOLD}Session:${C_RESET} connected for $(fmt_dur "$(ps -o etimes= -p "$(cat "$PID_FILE")" 2>/dev/null | tr -d ' ')")"
    fi
    if [ -r "$WATCH_LIB/current" ]; then
      local st ws eg; read -r st ws _ < "$WATCH_LIB/current"
      eg=$(grep -o ' eg=[0-9.]*' "$SAMPLES" 2>/dev/null | tail -n1 | cut -d= -f2 || true)
      echo -e "    ${C_BOLD}Diagnosis:${C_RESET} ${st} ($(fmt_dur $(( $(now_s) - ws ))))${eg:+   last egress ${eg}}"
    fi
  else
    case "$ph" in
      failed:*) title "  VPN status: ${C_RED}🔴 Stopped (${ph#failed:})${C_RESET}  ${C_GREY}details: menu 4${C_RESET}" ;;
      *)        title "  VPN status: ${C_RED}🔴 Stopped${C_RESET}" ;;
    esac
    if is_vpn_running; then
      echo -e "    ${C_YELLOW}Found an openconnect not managed by systemd (started by an old version?). Choose 3 to stop it, then 1 to start.${C_RESET}"
    fi
    echo -e "    ${C_BOLD}Will use:${C_RESET} $(cfg_label ACCOUNT)  /  ${CFG[MODE]}  /  $(account_field "${CFG[ACCOUNT]}" 6 2>/dev/null || true)${CFG[PROTOCOL]}  /  $(cfg_label DATA_CHANNEL)"
  fi
  echo -e "    ${C_BOLD}Shortcut:${C_RESET} $(_shortcut_state)   ${C_GREY}ocm -h for command-line usage${C_RESET}"
  sep
}

status_menu() {
  local c
  while true; do
    clear 2>/dev/null || true; cmd_status -v || true; sep
    echo "  1) Diagnostic report (last 1 day)   2) Last 7 days   3) Last 30 days"
    echo "  4) Last 60 lines of openconnect output   5) Save an incident snapshot now   0) Back"
    read -rp "Select: " c || return 0
    case "$c" in
      1) cmd_report 1 | less -R -F -X || true ;;
      2) cmd_report 7 | less -R -F -X || true ;;
      3) cmd_report 30 | less -R -F -X || true ;;
      4) tail -n 60 "$OCLOG" 2>/dev/null || echo "(nothing yet)"; _pause ;;
      5) cmd_log snapshot menu || true; _pause ;;
      *) return 0 ;;
    esac
  done
}

main_menu() {
  local c
  clear 2>/dev/null || true
  echo -e "${C_BOLD}========================================================${C_RESET}"
  echo -e "${C_BOLD}  🚀 OpenConnect Master Manager v${VERSION} 🚀${C_RESET}"
  echo -e "${C_BOLD}========================================================${C_RESET}"
  settings_load
  show_status || true
  title "Main Menu:"
  echo -e "  ${C_GREEN}1) 🚀 Start VPN (current settings, confirm before starting)${C_RESET}"
  echo -e "  ${C_GREEN}2) 🔁 Restart VPN (apply new settings)${C_RESET}"
  echo -e "  ${C_RED}3) ⏹  Stop VPN${C_RESET}"
  echo -e "  4) 📊 Status details & diagnostic report"
  sep
  echo -e "  5) ⚙️  Settings (mode / protocol / data channel / proxy / reconnect / logging...)"
  echo -e "  6) 🔐 Manage VPN accounts"
  echo -e "  7) 🗓️  Scheduled start / stop"
  echo -e "  8) 📦 Check/install dependencies"
  echo -e "  9) 🧪 ${C_CYAN}Test Netns IPv6 connectivity${C_RESET}"
  echo -e " 10) 🗑️  Uninstall"
  echo -e "  0) 🚪 Exit"
  echo
  read -rp "Please select [0-10]: " c || { echo; log_info "Standard input ended, exiting."; exit 0; }
  case "$c" in
    1) OVR=(); cmd_start 1 || true ;;
    2) if svc_active; then OVR=(); cmd_stop || true; sleep 2; fi; cmd_start 1 || true ;;
    3) cmd_stop || true ;;
    4) status_menu ;;
    5) settings_menu ;;
    6) manage_accounts ;;
    7) manage_cron ;;
    8) manage_deps || true ;;
    9) if [ -f "$STATE_FILE" ] && grep -q "MODE=netns" "$STATE_FILE"; then test_netns_ipv6 || true; else log_err "Netns mode is not running, cannot test"; fi ;;
    10) uninstall; exit 0 ;;
    0) exit 0 ;;
    *) log_err "Invalid option '$c'" ;;
  esac
  [[ "$c" =~ ^([1-3]|8|9)$ ]] && _pause "Press any key to return to the main menu..."
  return 0
}

# ============================================================================
#  Command line
# ============================================================================
usage() { cat <<EOF
OpenConnect Master Manager v${VERSION}

Usage: ocm [command] [options]
  (no arguments)           open the interactive menu
  start [options]          start with the saved settings (managed by systemd); options affect this run only
      -a, --account N|name     use account number N / the account with this name
      -m, --mode MODE          netns | default | ocproxy
      -p, --proto PROTO        anyconnect | pulse | nc | gp | fortinet | array
      -P, --port N             SOCKS5 port
          --listen ADDR        127.0.0.1 | 0.0.0.0
          --tls-only | --dtls  data channel: TLS only (--no-dtls) / ESP·DTLS
          --fwd socat|iptables port forwarding method
          --kill-switch on|off kill switch
          --dns fast|system    DNS timeout policy
          --mtu N|auto         tunnel MTU
          --oc-args "..."      extra arguments for openconnect
          --save               save this run's options as the defaults
      -i, --interactive        show a summary and confirm before starting (what menu start does)
  stop                     stop the VPN (cleans up after openconnect logs out normally)
  restart [options]        stop, then start with the (new) settings
  status [-v]              run state, diagnostic verdict, recent events
  log report [days]        outage stats / session timeline / auto reconnect records (default 7 days)
  log tail                 follow events and openconnect output live
  log snapshot [tag]       save an incident snapshot now
  log mark <text>          put a mark into the event log
  heal on|off|status       auto reconnect switch
  config list [-v]         list all settings (-v adds descriptions)
  config get KEY           read one setting
  config set KEY VALUE     change one setting (for SOCKS5 auth use SOCKS_USER / SOCKS_PASS)
  accounts                 list accounts (passwords not shown)
  install-service          install/refresh the systemd units (done automatically on start)
  uninstall-service        remove the systemd units (settings and logs are kept)
  -V, --version            version
  -h, --help               this help

Files: settings ${SETTINGS_FILE}   accounts ${ACCOUNTS_FILE}   logs ${LOG_DIR}
Exit codes: 0 success  1 failure  2 usage error  3 already running / state conflict
Examples:
  ocm start -m netns -p nc -P 8585 --tls-only --save
  ocm log report 7
  ocm config set DEGRADED_WAIT 60
EOF
}

INTERACTIVE=0
_ovr() { settings_validate "$1" "$2" || exit 2; OVR[$1]=$2; }
parse_start_opts() {
  local idx
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--account) [ $# -ge 2 ] || { log_err "$1 requires an argument"; exit 2; }
                    idx=$(account_resolve "$2") || { log_err "Account not found: $2"; exit 2; }; OVR[ACCOUNT]=$idx; shift 2 ;;
      -m|--mode) [ $# -ge 2 ] || exit 2; _ovr MODE "$2"; shift 2 ;;
      -p|--proto|--protocol) [ $# -ge 2 ] || exit 2; _ovr PROTOCOL "$2"; shift 2 ;;
      -P|--port) [ $# -ge 2 ] || exit 2; _ovr SOCKS_PORT "$2"; shift 2 ;;
      --listen) [ $# -ge 2 ] || exit 2; _ovr LISTEN "$2"; shift 2 ;;
      --tls-only|--no-dtls) OVR[DATA_CHANNEL]=tls; shift ;;
      --dtls) OVR[DATA_CHANNEL]=dtls; shift ;;
      --fwd|--forwarder) [ $# -ge 2 ] || exit 2; _ovr FORWARDER "$2"; shift 2 ;;
      --kill-switch) [ $# -ge 2 ] || exit 2; _ovr KILL_SWITCH "$2"; shift 2 ;;
      --dns) [ $# -ge 2 ] || exit 2
             case "$2" in fast|on) OVR[DNS_FAST]=on ;; system|off) OVR[DNS_FAST]=off ;; *) log_err "--dns must be fast|system"; exit 2;; esac; shift 2 ;;
      --mtu) [ $# -ge 2 ] || exit 2; _ovr MTU "$2"; shift 2 ;;
      --oc-args) [ $# -ge 2 ] || exit 2; _ovr OC_EXTRA "$2"; shift 2 ;;
      --save) OPT_SAVE=1; shift ;;
      -i|--interactive) INTERACTIVE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log_err "Unknown option: $1"; echo "Run ocm -h for usage" >&2; exit 2 ;;
    esac
  done
}

cmd_heal() {
  check_root; settings_load
  case "${1:-status}" in
    on|off) CFG[AUTO_RECONNECT]=$1; settings_save; ev "CONFIG AUTO_RECONNECT -> $1"
            log "Auto reconnect: $(cfg_label AUTO_RECONNECT) (a running supervisor applies the new value at the next disconnect)"
            [ "$1" = on ] && ! svc_active && [[ "$(get_phase)" == failed:* ]] && log_info "Last stopped because of $(get_phase); after checking the cause, start again with ocm start." ;;
    status) echo "Auto reconnect: $(cfg_label AUTO_RECONNECT)   VPN service: $(systemctl is-active "$SVC_MAIN" 2>/dev/null || true)   phase: $(get_phase)"
            grep -aE ' SUP (exit|paused|rate-limited|retry) | WATCH restart-request ' "$EVENTS" 2>/dev/null | tail -n 10 | cut -c1-200 | sed 's/^/  /' || true ;;
    *) log_err "Usage: ocm heal on|off|status"; return 2 ;;
  esac
}

cmd_config() {
  check_root; settings_load
  local sub="${1:-list}" k
  case "$sub" in
    list)
      for k in "${SET_KEYS[@]}"; do
        [ "$k" = SOCKS_AUTH ] && { printf '%-18s = %s\n' "SOCKS_USER" "${CFG[SOCKS_USER]}"; printf '%-18s = %s\n' "SOCKS_PASS" "$( [ -n "${CFG[SOCKS_PASS]}" ] && echo '****')"; continue; }
        printf '%-18s = %-24s # %s: %s\n' "$k" "${CFG[$k]}" "${SET_TITLE[$k]}" "$(cfg_label "$k")"
        [ "${2:-}" = -v ] && _set_help "$k" | sed 's/^/      /'
      done; return 0 ;;
    get) [ -n "${2:-}" ] && _is_cfg_key "$2" || { log_err "Unknown setting: ${2:-}"; return 2; }; printf '%s\n' "${CFG[$2]}" ;;
    set) [ $# -ge 3 ] || { log_err "Usage: ocm config set KEY VALUE"; return 2; }
         _is_cfg_key "$2" || { log_err "Unknown setting: $2 (see ocm config list)"; return 2; }
         local v="$3"; [ "$2" = ACCOUNT ] && { v=$(account_resolve "$3") || { log_err "Account not found: $3"; return 2; }; }
         settings_validate "$2" "$v" || return 2
         local old=${CFG[$2]}; CFG[$2]=$v; settings_save
         if [ "$2" = SOCKS_PASS ]; then ev "CONFIG SOCKS_PASS changed"; else ev "CONFIG $2: $old -> $v"; fi
         log "$2 = $( [ "$2" = SOCKS_PASS ] && echo '****' || cfg_label "$2")"
         case "$2" in WATCH|AUTOSTART) apply_service_prefs ;; esac
         case "$SET_NEEDS_RESTART" in *" $2 "*) svc_active && log_warn "VPN is running: takes effect after a restart (ocm restart).";; esac
         [[ "$2" =~ ^SOCKS_(USER|PASS)$ ]] && svc_active && log_warn "VPN is running: takes effect after a restart (ocm restart)."
         return 0 ;;
    *) log_err "Usage: ocm config list [-v] | get KEY | set KEY VALUE"; return 2 ;;
  esac
}

# --- Script entry point ---
main_entry() {
  case "${1:-}" in
    "")            check_root; _ensure_shortcut; while true; do main_menu; done ;;
    -h|--help|help) usage ;;
    -V|--version|version) echo "OpenConnect Master Manager v${VERSION}" ;;
    start)         shift; parse_start_opts "$@"; cmd_start "$INTERACTIVE" ;;
    restart)       shift; parse_start_opts "$@"; check_root; cmd_stop; sleep 2; cmd_start "$INTERACTIVE" ;;
    stop)          cmd_stop ;;
    status)        shift; cmd_status "${1:-}" ;;
    log|logs)      shift; cmd_log "$@" ;;
    heal)          shift; cmd_heal "$@" ;;
    config)        shift; cmd_config "$@" ;;
    accounts)      check_root; accounts_list ;;
    install-service)   check_root; settings_load; install_units && log "systemd units are ready: $SVC_MAIN / $SVC_WATCH" ;;
    uninstall-service) check_root; uninstall_units; log "systemd units removed (settings and logs kept)" ;;
    _supervise)    _supervise ;;
    _watch)        _watch ;;
    _internal_*)   echo "[$VR_TAG] The legacy cron guard has been replaced by systemd auto reconnect; remove that scheduled task in menu 7." >&2; exit 0 ;;
    *)             log_err "Unknown command: $1"; echo "Run ocm -h for usage" >&2; exit 2 ;;
  esac
}
main_entry "$@"
