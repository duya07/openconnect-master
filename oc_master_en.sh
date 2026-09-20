#!/bin/bash
# =================================================================
#   OpenConnect Master Manager - v7.7.7 (Final)
#   - Final: Simplified ocproxy mode, removed remote connection option, listens locally by default.
#   - Fix(Netns): Enhanced IPv6 detection in show_status, improving success rate through multiple methods (increased timeout, fallback check points, direct netns connection).
#   - Enhancement(Netns): socat forwarding now supports dual-stack (IPv4 & IPv6) listening.
#   - New(Netns): Added active IPv6 connectivity test function at startup and in the menu.
#   - New: OpenConnect protocol selection, supporting AnyConnect / Pulse(Ivanti) / NC(Juniper).
#   - Removed(Netns): iptables DNAT fallback forwarder (measured: under a global VPN inside
#     the netns replies are swallowed by tun, so its data plane is dead). socat is now
#     required; cleanup of legacy state is still kept for compatibility.
#   - Improved: the ocm shortcut is installed automatically at startup and shown in the
#     status area (no longer its own menu item); the main menu is a compact two-column layout.
# =================================================================
set -euo pipefail

# --- Global Configuration ---
VR_TAG="OC-Master-v7.7.7-Final"
SCRIPT_PATH="$(readlink -f "$0")"
PID_FILE="/var/run/oc_manager.pid"
GOST_PID_FILE="/var/run/oc_gost.pid"
SOCAT_PID_FILE="/var/run/oc_socat.pid"
SOCAT_PID_FILE_V6="${SOCAT_PID_FILE}.v6"
STATE_FILE="/var/run/oc_manager.state"
ACCOUNTS_FILE="/root/.vpn_accounts.env"
SHORTCUT_PATH="/usr/local/bin/ocm"
# Dependency marker: records only the dependencies THIS script installed. Uninstall
# uses it to tell them apart - what we installed is offered for removal by default,
# what was already on the box is kept by default with a warning, so nobody deletes
# something another program still uses. Machines upgraded from an older version have
# no marker file, so every dependency counts as "already there" (the safe direction).
DEPS_STATE_DIR="/var/lib/oc-master"
DEPS_MARK_FILE="${DEPS_STATE_DIR}/installed-deps"

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
log()      { echo -e "${C_GREEN}✅ [$VR_TAG] $1${C_RESET}"; }
log_err()  { echo -e "${C_RED}❌ [$VR_TAG] $1${C_RESET}" >&2; }
log_info() { echo -e "${C_CYAN}ℹ️  [$VR_TAG] $1${C_RESET}"; }
log_warn() { echo -e "${C_YELLOW}⚠️  [$VR_TAG] $1${C_RESET}"; }
title()    { echo -e "${C_BOLD}$1${C_RESET}"; }
sep()      { echo -e "${C_GREY}────────────────────────────────────────────────────────${C_RESET}"; }
check_root(){ [ "$EUID" -eq 0 ] || { log_err "Please run as root"; exit 1; }; }

# Terminal display width: non-ASCII (CJK etc.) counts as 2 columns, used to align the
# two-column menu. UTF-8 locale is set explicitly - the script may be invoked from cron
# or from an environment without LANG, where wc -m degrades to byte counts and the width
# math (and therefore the menu) would be wrong.
_disp_w() {
  local s="$1" c b
  c=$(printf '%s' "$s" | LC_ALL=C.UTF-8 wc -m)
  b=$(printf '%s' "$s" | LC_ALL=C wc -c)
  echo $(( c + (b - c) / 2 ))
}
_pad() { # left-align, padded with spaces to N columns (must return 0: used as an AND-list tail)
  local s="$1" w="$2" cur
  cur=$(_disp_w "$s")
  printf '%s' "$s"
  [ "$cur" -lt "$w" ] && printf '%*s' "$(( w - cur ))" ''
  return 0
}

# --- ocm Shortcut Command ---
# Use a symlink instead of a copy: the script resolves its own real path with
# readlink -f "$0", so calling it through /usr/local/bin/ocm behaves exactly the
# same (menu, ocm stop and _internal_* all keep working).
# Only takes over a link that already points at this script; an existing real
# file at that path is never overwritten.
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
  # A symlink requires the target itself to be executable. The normal install
  # flow already runs chmod +x, but if the script was started with
  # `bash oc_master_en.sh` the execute bit may be missing, so add it here.
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

# Ensures the shortcut command exists when the script starts (it no longer occupies a
# menu item). Three cases are left untouched:
#   - the script lives in /tmp or another temp dir (just downloaded, or under test)
#     -> never create a link that points at a temporary file
#   - a real file, or a symlink pointing elsewhere -> may belong to another program
# Only a dangling symlink is taken over: that is what a moved/deleted copy leaves behind.
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

# One-line summary for the main menu status area (plain text; the caller adds colour)
_shortcut_state() {
  local tgt="" base=""
  if [ -L "$SHORTCUT_PATH" ]; then
    tgt="$(readlink -f "$SHORTCUT_PATH" 2>/dev/null || true)"
    if [ "$tgt" = "$SCRIPT_PATH" ]; then echo "ocm ✓"
    elif [ -n "$tgt" ]; then base="$(basename "$tgt")"; echo "ocm → ${base}"
    else echo "ocm dangling link"; fi
  elif [ -e "$SHORTCUT_PATH" ]; then
    echo "ocm is not our link"
  else
    echo "ocm not installed"
  fi
  return 0
}

# --- Interrupt Handling ---
cleanup_on_interrupt() {
  log_err "\nOperation interrupted by user (Ctrl+C). Performing emergency cleanup..."
  stop_vpn
  exit 1
}

# --- Dependency Checks ---
_mark_dep_installed() {
  local name="$1"
  mkdir -p "$DEPS_STATE_DIR" 2>/dev/null || return 0
  if ! grep -qxF "$name" "$DEPS_MARK_FILE" 2>/dev/null; then
    echo "$name" >> "$DEPS_MARK_FILE" 2>/dev/null || true
  fi
  return 0
}
# 0 = this script installed it; non-zero = it was already there (or no marker file)
_dep_installed_by_us() { grep -qxF "$1" "$DEPS_MARK_FILE" 2>/dev/null; }

# Removable dependencies: marker name|command|purpose. iptables/iproute2 are core
# system packages and are deliberately not listed.
_DEPS_LIST=(
  "openconnect|openconnect|VPN client (needed by all three modes)"
  "ocproxy|ocproxy|ocproxy mode"
  "gost|gost|SOCKS5 server for Netns mode"
  "socat|socat|Port forwarding for Netns mode (required)"
)

# Menu 7: scan the current state first, then decide what to install
show_deps() {
  local entry name cmd desc state
  title "📦 Dependency status:"
  for entry in "${_DEPS_LIST[@]}"; do
    IFS='|' read -r name cmd desc <<< "$entry"
    if command -v "$cmd" &>/dev/null; then
      if _dep_installed_by_us "$name"; then
        state="${C_GREEN}✔ installed${C_RESET} ${C_GREY}(installed by this script, safe to remove)${C_RESET}"
      else
        state="${C_GREEN}✔ installed${C_RESET} ${C_YELLOW}(pre-existing, kept by default on uninstall)${C_RESET}"
      fi
    else
      state="${C_RED}✘ missing${C_RESET}"
    fi
    # echo -e is required: the colour variables hold a literal \033[...m and
    # printf's %s does not expand escapes.
    printf '  %-12s ' "$name"
    echo -e "${desc}  ${state}"
  done
  sep
}
manage_deps() {
  show_deps
  local entry name cmd desc todo=() ans=""
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
_install_gost_now() { # installs only, never prompts (the caller already asked)
  log_info "Installing gost using the official script..."
  if ! command -v curl &>/dev/null; then _pkg_install curl; fi
  bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install || {
    log_err "gost installation script failed. Please check your network or try installing it manually."
    return 1
  }
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
  read -rp "Do you want to auto-install gost using the official script now? [Y/n]: " yn || yn=""
  [[ "$yn" =~ ^[nN]$ ]] && { log_err "User cancelled installation. Netns mode cannot be started."; return 1; }
  _install_gost_now
}
ensure_cmd_socat() {
  command -v socat &>/dev/null && return 0
  log_warn "Netns mode requires 'socat' for port forwarding (the only forwarder)."
  local yn=""
  read -rp "Do you want to install socat now? [Y/n]: " yn || yn=""
  [[ "$yn" =~ ^[nN]$ ]] && { log_err "socat is missing, Netns mode cannot start."; return 1; }
  _pkg_install socat
  command -v socat &>/dev/null || { log_err "socat installation failed, Netns mode cannot start."; return 1; }
  _mark_dep_installed socat
  log "socat has been installed."
  return 0
}
check_atd() { if ! command -v at &>/dev/null || ! systemctl is-active --quiet atd; then log_warn "at/atd is missing or not running, attempting to install and start..."; _pkg_install at; systemctl enable --now atd 2>/dev/null || log_err "Failed to start atd automatically"; fi; }

# Same usage as `grep -q`, but safe at the end of a pipeline under `set -o pipefail`.
# Trap: in `cmd | grep -q PAT` grep exits on its first match, so cmd gets SIGPIPE
# (exit 141) while writing the rest of its output, and pipefail then reports the whole
# pipeline as failed - a successful match is treated as "no match".
# Measured: `ip netns exec NS ip link show | grep -q 'tun.*UP'` failed 262/1500 ~ 17%
# of the time, which made Netns mode intermittently log "TUN ready" and then "start
# failed" even though the tunnel was fine.
# `grep -c` has to read all of its input before printing, so it never breaks the
# producer, and it reports the same match/no-match status as -q.
_gq() { grep -c "$@" >/dev/null; }

# Wait for a process to exit, at most 10 seconds, then SIGKILL it.
# Needed by netns mode: killing openconnect and immediately running cleanup_netns
# tears down the veth->NAT path it logs out over, so openconnect just hangs on a TLS
# timeout (observed lingering well over 80 seconds) and the leftover session fights
# the next connection.
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
# With a single provider (ip.p3terx.com) the whole status block degrades to
# "Query failed" whenever that one host is down -- measured: ip.p3terx.com is now
# unreachable entirely (80/443 both "Failed to connect", 0/10 successes), so fall
# back through several providers, fastest-measured first.
_PUB_PROVIDERS4=("https://api.ipify.org" "https://ifconfig.me/ip" "https://ip.p3terx.com")
# IPv6 is usually unavailable; failing fast matters more than coverage here.
_PUB_PROVIDERS6=("https://api64.ipify.org" "https://ifconfig.me/ip")
# $1=-4/-6; $2=optional socks5h proxy. Prints the address, or returns 1 if all fail.
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

# --- IPv6 Connectivity Test ---
test_netns_ipv6() {
  local test_passed=0
  log_info "Testing IPv6 connectivity inside Netns..."
  if ! "$IP_CMD" netns list | _gq "${NETNS_NAME}"; then log_err "Netns ${NETNS_NAME} does not exist, cannot perform test."; return 1; fi
  
  # Test 1: Check for IPv6 address
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
  
  # Test 3: HTTP IPv6 Request
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

# --- Core Network Functions ---
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

# --- SSH Protection Routes (Used by Default Mode) ---
setup_ssh_protect_routes() {
  local gw_dev="" gw4="" vps4="" default_ipv6_route="" vps6="" gw6_addr="" gw6_if="" onlink_flag=""
  gw_dev=$("$IP_CMD" route | awk '/^default/ {print $5; exit}')
  gw4=$("$IP_CMD" route | awk '/^default/ {print $3; exit}')
  vps4=$("$IP_CMD" -4 -o addr show dev "$gw_dev" | awk '{print $4}' | cut -d/ -f1 | head -n1)

  check_rt_conflict "$RT4_ID" "$RT4_NAME"
  log "Configuring IPv4 policy routing (for SSH protection)..."
  "$IP_CMD" route replace default via "$gw4" dev "$gw_dev" table "$RT4_ID"
  "$IP_CMD" rule del from "$vps4" table "$RT4_ID" priority 500 2>/dev/null || true
  "$IP_CMD" rule add from "$vps4" table "$RT4_ID" priority 500
  log "IPv4 OK (from $vps4)"

  default_ipv6_route=$("$IP_CMD" -6 route | awk '/^default/ && $0 !~ /tun/ {print; exit}' || true)
  vps6=$("$IP_CMD" -6 -o addr show dev "$gw_dev" scope global | awk '{print $4; exit}' | cut -d/ -f1 || true)
  if [ -n "$default_ipv6_route" ] && [ -n "$vps6" ]; then
    gw6_addr=$(echo "$default_ipv6_route" | awk '{print $3}')
    gw6_if=$(echo "$default_ipv6_route" | awk '{print $5}')
    echo "$default_ipv6_route" | grep -q " onlink " && onlink_flag="onlink" || onlink_flag=""
    check_rt_conflict "$RT6_ID" "$RT6_NAME"
    log "Configuring IPv6 policy routing (for SSH protection)..."
    "$IP_CMD" -6 route replace default via "$gw6_addr" dev "$gw6_if" $onlink_flag table "$RT6_ID"
    "$IP_CMD" -6 rule del from "$vps6" table "$RT6_ID" priority 500 2>/dev/null || true
    "$IP_CMD" -6 rule add from "$vps6" table "$RT6_ID" priority 500
    log "IPv6 OK (from $vps6)"
  else
    log_info "No available IPv6 default route or address, skipping IPv6 setup"
    vps6="" # ensure vps6 is empty
  fi

  { echo "VPS4=${vps4:-}"; echo "VPS6=${vps6:-}"; } > "$STATE_FILE"
}

# --- Network Namespace Management ---
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
  
  log_info "Enabling kernel IP forwarding..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

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
  # setup_netns writes a resolv.conf into /etc/netns/<name>/ (ip netns exec bind-mounts
  # it over /etc/resolv.conf). Remove it here too, otherwise every Netns run leaves a
  # directory behind on the system, and it survives uninstalling the script.
  rm -rf "/etc/netns/${NETNS_NAME}" 2>/dev/null || true
  log "Netns base environment has been cleaned up."
}

# --- Account Management ---
manage_accounts() {
  [ -f "$ACCOUNTS_FILE" ] || { tee "$ACCOUNTS_FILE" >/dev/null <<'EOT'
# Format: Display Name|Username|Password|VPN Host|Auth Group(Optional)
EOT
    chmod 600 "$ACCOUNTS_FILE" || true; }
  # c must be local: otherwise this submenu overwrites the main menu's option
  # variable, and main_menu's "press any key" test then uses the wrong value
  # (a spurious extra pause that also eats one character of the next input).
  local c
  while true; do
    clear; title "🔐 Manage VPN Accounts ($ACCOUNTS_FILE)"; sep
    grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE" | nl -ba || log_info "  File is empty."
    sep; echo "  1) Add  2) Delete  3) Back"; read -rp "Select [1-3]: " c
    case "$c" in
      1) read -rp "Display Name: " d; read -rp "User: " u; read -sp "Password: " p; echo; read -rp "Host: " h; read -rp "Auth Group (Optional): " g
         [ -z "$d" ] || [ -z "$u" ] || [ -z "$p" ] || [ -z "$h" ] && { log_err "Required fields cannot be empty"; read -n1 -s -p "Press any key to continue"; continue; }
         echo "$d|$u|$p|$h|$g" >> "$ACCOUNTS_FILE"; chmod 600 "$ACCOUNTS_FILE" || true; log "Added $d"; read -n1 -s -p "Press any key to continue";;
      2) mapfile -t A < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE"); [ ${#A[@]} -eq 0 ] && { log_info "No accounts found"; sleep 1; continue; }
         read -rp "Enter the number to delete: " i; [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#A[@]}" ] || { log_err "Invalid number"; continue; }
         # Delete exactly the i-th entry of the filtered list. The old grep -vF approach had
         # two problems: (1) deleting the last entry produced no output, grep returned 1, so
         # `&& mv` never ran - the file stayed unchanged while "Deleted" was printed anyway
         # (false success) and a .tmp file was left behind; (2) two identical accounts were
         # both removed at once.
         if ! awk -v n="$i" 'BEGIN{k=0} /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next} {k++; if (k!=n) print}' "$ACCOUNTS_FILE" > "${ACCOUNTS_FILE}.tmp"; then
           log_err "Delete failed: cannot write the temporary file."; rm -f "${ACCOUNTS_FILE}.tmp"; read -n1 -s -p "Press any key to continue"; continue
         fi
         mv "${ACCOUNTS_FILE}.tmp" "$ACCOUNTS_FILE"; chmod 600 "$ACCOUNTS_FILE" || true; log "Deleted"; read -n1 -s -p "Press any key to continue";;
      3) break;;
      *) log_err "Invalid option"; sleep 1;;
    esac
  done
}
select_account() {
  mapfile -t ACC < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE")
  [ ${#ACC[@]} -gt 0 ] || { log_err "Account file is empty or invalid"; manage_accounts; return 1; }
  log_info "Please select a VPN account:"; local i=0; for a in "${ACC[@]}"; do i=$((i+1)); echo "  $i) $(echo "$a" | cut -d'|' -f1)"; done; echo "  99) Back"
  read -rp "Enter number: " idx; [ "$idx" = "99" ] && return 1
  [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#ACC[@]}" ] || { log_err "Invalid selection"; return 1; }
  local choice="${ACC[$((idx-1))]}"; export ACCOUNT_INDEX="$((idx-1))"
  export VPN_DESC=$(echo "$choice" | cut -d'|' -f1)
  export VPN_USER=$(echo "$choice" | cut -d'|' -f2)
  export VPN_PASS=$(echo "$choice" | cut -d'|' -f3)
  export VPN_HOST=$(echo "$choice" | cut -d'|' -f4)
  export VPN_GROUP=$(echo "$choice" | cut -d'|' -f5)
  log_info "Loaded: $VPN_DESC"
}
select_protocol() {
  local p=""
  echo
  title "🔌 Please select the OpenConnect protocol:"
  echo "  1) AnyConnect  - Cisco AnyConnect (default)"
  echo "  2) Pulse       - Pulse Secure / Ivanti Secure Access"
  echo "  3) NC          - Juniper Network Connect"
  echo "  99) Back"
  read -rp "Select [1-3, default 1]: " p
  case "${p:-1}" in
    1) export VPN_PROTOCOL="anyconnect"; export VPN_PROTOCOL_DESC="Cisco AnyConnect" ;;
    2) export VPN_PROTOCOL="pulse";      export VPN_PROTOCOL_DESC="Pulse / Ivanti" ;;
    3) export VPN_PROTOCOL="nc";         export VPN_PROTOCOL_DESC="Juniper NC" ;;
    99) return 1 ;;
    *) log_err "Invalid protocol selection"; return 1 ;;
  esac
  log_info "Protocol selected: ${VPN_PROTOCOL_DESC} (--protocol=${VPN_PROTOCOL})"
}

_load_account_by_index() {
  local idx="$1"; mapfile -t ACC < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE")
  [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt "${#ACC[@]}" ] || { log_err "Invalid account index: $idx"; exit 1; }
  local choice="${ACC[$idx]}"; export ACCOUNT_INDEX="$idx"
  export VPN_DESC=$(echo "$choice" | cut -d'|' -f1); export VPN_USER=$(echo "$choice" | cut -d'|' -f2);
  export VPN_PASS=$(echo "$choice" | cut -d'|' -f3); export VPN_HOST=$(echo "$choice" | cut -d'|' -f4);
  export VPN_GROUP=$(echo "$choice" | cut -d'|' -f5);
}

# --- Core Start/Stop Logic ---
_execute_with_safety_net() {
  local func_to_run="$1"
  trap cleanup_on_interrupt SIGINT
  check_atd
  local job; job=$(echo "$SCRIPT_PATH stop" | at now + 2 minutes 2>&1 | awk '/job/{print $2}' || echo "none")
  [ "$job" != "none" ] && log_warn "Failsafe cleanup job set (Job $job). Will auto-rollback if connection fails within 2 minutes."

  if "$func_to_run"; then
    trap - SIGINT # Success, remove the trap
    [ "$job" != "none" ] && atrm "$job" && log "Connection stable, failsafe job cancelled."
    show_status || true
  else
    trap - SIGINT # Failure, remove the trap
    log_err "Startup process failed, please check the logs."
    stop_vpn # Ensure cleanup is also run on internal function failure
    # Cleanup already happened above, so the failsafe job must be cancelled too:
    # otherwise it runs its `stop` exactly 2 minutes later, when the user has very
    # likely reconnected, and the previous failure kills the current session
    # (observed as consecutive starts fighting each other).
    [ "$job" != "none" ] && atrm "$job" 2>/dev/null || true
  fi
}

start_default() { is_vpn_running && { log_err "VPN is already running"; return; }; ensure_pkg_openconnect; select_account || return; select_protocol || return; _execute_with_safety_net "_start_default_logic"; }
_start_default_logic() {
  setup_ssh_protect_routes
  { echo "MODE=default"; echo "ACCOUNT_INDEX=$ACCOUNT_INDEX"; echo "VPN_PROTOCOL=${VPN_PROTOCOL:-anyconnect}"; } | tee -a "$STATE_FILE" >/dev/null
  log_info "Connecting to VPN [Default Mode / Protocol: ${VPN_PROTOCOL:-anyconnect}]: $VPN_HOST ..."
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol="${VPN_PROTOCOL:-anyconnect}" --user="$VPN_USER" --passwd-on-stdin -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "${oc_cmd[@]}"
  log_info "Waiting for TUN interface to be ready..."; for ((i=0;i<15;i++)); do if is_vpn_running && ip link show 2>/dev/null | _gq 'tun.*UP'; then log "VPN connected successfully (PID=$(cat "$PID_FILE"))"; return 0; fi; sleep 1; done
  log_err "VPN connection failed or timed out"; return 1
}

start_ocproxy_mode() { is_vpn_running && { log_err "VPN is already running"; return; }; ensure_pkg_openconnect; ensure_pkg_ocproxy; select_account || return; select_protocol || return; _execute_with_safety_net "_start_ocproxy_logic"; }
_start_ocproxy_logic() {
  local socks_port
  local listen_addr="127.0.0.1" # [Final] Simplified: listen locally by default, remove remote option
  # The daemon reconnect has no terminal (cron stdin is closed): read hits EOF and set -e
  # kills the whole reconnect flow (measured rc=1, exits in 0s - so the ocproxy health
  # daemon advertised by menu 6 never worked). When the caller passes reconnect, use the
  # SOCKS_PORT saved in state instead: skip the prompt; if the port is taken, give up this
  # round (the next cron cycle retries) rather than falling into the interactive loop.
  if [ "${1:-}" = "reconnect" ] && [[ "${SOCKS_PORT:-}" =~ ^[0-9]+$ ]]; then
    socks_port="$SOCKS_PORT"
    _check_port_free "$socks_port" || { log_err "Reconnect port ${socks_port} is currently in use, giving up this round"; return 1; }
  else
    while true;do read -rp "Please enter the SOCKS5 listening port (e.g. 1080): " socks_port; [[ "$socks_port" =~ ^[0-9]+$ ]]&&[ "$socks_port" -ge 1 ]&&[ "$socks_port" -le 65535 ]||{ log_err "Invalid port";continue; }; _check_port_free "$socks_port"||{ log_err "Port is already in use";continue; }; break; done
  fi
  
  log_info "Starting ocproxy mode (Protocol: ${VPN_PROTOCOL:-anyconnect}, listening on: $listen_addr)...";
  # [Final] Simplified: removed unused allow_arg variable
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol="${VPN_PROTOCOL:-anyconnect}" --user="$VPN_USER" --passwd-on-stdin --script-tun --script "ocproxy -k 30 -D $socks_port" -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "${oc_cmd[@]}"
  
  log_info "Waiting for ocproxy to start..."; for ((i=0;i<10;i++)); do if is_vpn_running; then log "ocproxy connected successfully (PID=$(cat "$PID_FILE"))"; echo "MODE=ocproxy">"$STATE_FILE";echo "ACCOUNT_INDEX=$ACCOUNT_INDEX" >> "$STATE_FILE";echo "VPN_PROTOCOL=${VPN_PROTOCOL:-anyconnect}" >> "$STATE_FILE";echo "SOCKS_PORT=$socks_port" >> "$STATE_FILE";echo "LISTEN_ADDR=$listen_addr" >> "$STATE_FILE"; return 0; fi; sleep 1; done
  log_err "ocproxy connection failed or timed out"; return 1
}

start_netns_mode() {
  is_vpn_running && { log_err "VPN is already running"; return; }
  ensure_pkg_openconnect
  ensure_cmd_gost || return
  ensure_cmd_socat || return # socat is the only port forwarder for Netns mode; without it nothing can start
  select_account || return
  select_protocol || return
  _execute_with_safety_net "_start_netns_logic"
}
_start_netns_logic() {
  local socks_port
  while true;do read -rp "Please enter the SOCKS5 listening port (e.g. 8585): " socks_port; [[ "$socks_port" =~ ^[0-9]+$ ]]&&[ "$socks_port" -ge 1 ]&&[ "$socks_port" -le 65535 ]||{ log_err "Invalid port";continue; }; _check_port_free "$socks_port" || { log_err "Port is already in use"; continue; }; break; done
  
  local listen_addr="127.0.0.1"
  read -rp "Allow remote connections (listen on 0.0.0.0)? [y/N]: " yn
  if [[ "$yn" =~ ^[yY]$ ]]; then
    listen_addr="0.0.0.0"
  fi
  
  setup_netns
  
  log_info "Starting OpenConnect in Netns (Protocol: ${VPN_PROTOCOL:-anyconnect})...";
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol="${VPN_PROTOCOL:-anyconnect}" --user="$VPN_USER" --passwd-on-stdin -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "$IP_CMD" netns exec "${NETNS_NAME}" "${oc_cmd[@]}"
  
  log_info "Waiting for OpenConnect to establish TUN interface...";
  for ((i=0; i<20; i++)); do
    if [ -f "$PID_FILE" ] && "$IP_CMD" netns pids "${NETNS_NAME}" | _gq -F "$(cat "$PID_FILE")" && \
       "$IP_CMD" netns exec "${NETNS_NAME}" ip link show 2>/dev/null | _gq 'tun.*UP'; then
      log "OpenConnect TUN interface is ready (PID=$(cat "$PID_FILE"))"; sleep 2; break
    fi
    sleep 1
  done
  
  if ! "$IP_CMD" netns exec "${NETNS_NAME}" ip link show 2>/dev/null | _gq 'tun.*UP'; then
    log_err "Failed to start OpenConnect in Netns or the TUN interface did not come up"; return 1
  fi

  log_info "Testing IPv4 connectivity via VPN inside Netns...";
  if "$IP_CMD" netns exec "${NETNS_NAME}" ping -c 1 -W 4 8.8.8.8 >/dev/null 2>&1; then
    log "VPN IPv4 connectivity inside Netns is OK"
  else
    log_warn "VPN IPv4 connectivity test inside Netns failed, but continuing anyway..."
  fi
  
  test_netns_ipv6 || true

  log_info "Starting SOCKS5 service (gost) in Netns..."
  "$IP_CMD" netns exec "${NETNS_NAME}" gost -L="socks5://0.0.0.0:${socks_port}" >/dev/null 2>&1 &
  local gost_pid=$!; echo "$gost_pid" > "$GOST_PID_FILE"
  sleep 1; if ! kill -0 "$gost_pid" 2>/dev/null; then log_err "gost failed to start in Netns"; return 1; fi
  log "SOCKS5 service (gost) started in Netns (PID: $gost_pid)"
  
  log_info "Configuring port forwarding from host to Netns..."
  local socat_pid_v4="" socat_pid_v6=""
  # Port forwarding uses socat only. The old iptables DNAT fallback was removed: with a
  # global VPN inside the netns (default dev tun0), gost's reply packets have a destination
  # outside the veth directly-connected subnet, so the netns default route pushes them into
  # tun and out through the VPN exit - the client never receives a reply (measured with
  # tcpdump); the data plane simply does not work. socat is a process-level forwarder:
  # client<->host socat and socat<->netns gost are two independent connections, and both
  # ends of the host<->netns leg live inside the veth directly-connected subnet, so it does
  # not depend on reply routing.
  socat TCP4-LISTEN:"${socks_port}",bind="${listen_addr}",fork,reuseaddr TCP4:"${VETH_NS_IP}:${socks_port}" >/dev/null 2>&1 &
  socat_pid_v4=$!; echo "$socat_pid_v4" > "$SOCAT_PID_FILE"
  sleep 1; if ! kill -0 "$socat_pid_v4" 2>/dev/null; then log_err "socat port forwarding failed to start"; return 1; fi

  if [[ "$listen_addr" == "0.0.0.0" ]] || [[ "$listen_addr" == "::" ]]; then
    socat TCP6-LISTEN:"${socks_port}",ipv6only=1,fork,reuseaddr TCP4:"${VETH_NS_IP}:${socks_port}" >/dev/null 2>&1 &
    socat_pid_v6=$!; echo "$socat_pid_v6" > "$SOCAT_PID_FILE_V6"
    log "Using socat for port forwarding (IPv4 PID: $socat_pid_v4, IPv6 PID: $socat_pid_v6)"
  else
    log "Using socat for port forwarding (PID: $socat_pid_v4)"
  fi

  {
    echo "MODE=netns"; echo "ACCOUNT_INDEX=$ACCOUNT_INDEX"; echo "VPN_PROTOCOL=${VPN_PROTOCOL:-anyconnect}"; echo "SOCKS_PORT=$socks_port";
    echo "LISTEN_ADDR=$listen_addr"; echo "GOST_PID=$gost_pid"; echo "FORWARDER=socat";
    [ -n "$socat_pid_v4" ] && echo "SOCAT_PID=${socat_pid_v4}";
    [ -n "$socat_pid_v6" ] && echo "SOCAT_PID_V6=${socat_pid_v6}";
  } > "$STATE_FILE"
  
  return 0
}

# --- Stop & Cleanup ---
cleanup_ssh_protect_routes() {
  local vps4="" vps6=""
  if [ -f "$STATE_FILE" ]; then
    log_info "🔍 Loading route info from state file for precise cleanup..."
    # || true: if the state file exists but lacks this key, grep returns 1, the assignment
    # fails and set -e aborts the whole cleanup (measured: it exited without cleaning a thing).
    vps4=$(grep '^VPS4=' "$STATE_FILE" | cut -d'=' -f2 || true)
    vps6=$(grep '^VPS6=' "$STATE_FILE" | cut -d'=' -f2 || true)
  else
    log_warn "State file not found, will attempt generic cleanup."
  fi

  [ -n "$vps4" ] && { "$IP_CMD" rule del from "$vps4" table "$RT4_NAME" priority 500 2>/dev/null || true; log "Attempted to clean IPv4 rule (from $vps4)"; }
  [ -n "$vps6" ] && { "$IP_CMD" -6 rule del from "$vps6" table "$RT6_NAME" priority 500 2>/dev/null || true; log "Attempted to clean IPv6 rule (from $vps6)"; }
  
  log_info "🧹 Cleaning up all remaining rules pointing to $RT4_NAME and $RT6_NAME..."
  while "$IP_CMD" rule del table "$RT4_NAME" 2>/dev/null; do log "  -> Cleaned one orphaned IPv4 rule"; done
  while "$IP_CMD" -6 rule del table "$RT6_NAME" 2>/dev/null; do log "  -> Cleaned one orphaned IPv6 rule"; done

  "$IP_CMD" route flush table "$RT4_ID" 2>/dev/null || true
  "$IP_CMD" -6 route flush table "$RT6_ID" 2>/dev/null || true
  log "✅ Policy routing has been thoroughly cleaned up"
}

stop_vpn() {
  # Do not take the early exit while the state file exists: a failed start has already
  # written state and installed policy routes; the early exit skips
  # cleanup_ssh_protect_routes and rm, leaving a stale ip rule and state behind (measured:
  # iprule left at 4 lines; with the health cron installed it would also retry the bad
  # account every 5 minutes).
  if ! is_vpn_running && ! [ -f "$GOST_PID_FILE" ] && ! [ -f "$SOCAT_PID_FILE" ] && ! [ -f "$STATE_FILE" ]; then log_info "VPN is not running"; return; fi
  log_info "Stopping VPN and cleaning up environment...";
  # || true: this one is especially dangerous - the assignment is the last command of an
  # `[ -f ] && ...` list, so a failure aborts stop_vpn entirely: no process killed, no temp
  # files removed, no safety-net job cancelled (measured rc=1 with nothing cleaned up).
  local MODE; [ -f "$STATE_FILE" ] && MODE=$(grep '^MODE=' "$STATE_FILE" | cut -d'=' -f2 || true)

  case "${MODE:-unknown}" in
    netns)
      log_info "Stopping netns mode..."
      if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE" 2>/dev/null || true
        if [ "${FORWARDER:-}" = "socat" ]; then
          [ -f "$SOCAT_PID_FILE" ] && kill "$(cat "$SOCAT_PID_FILE")" 2>/dev/null || true
          [ -f "$SOCAT_PID_FILE_V6" ] && kill "$(cat "$SOCAT_PID_FILE_V6")" 2>/dev/null || true
        elif [ "${FORWARDER:-}" = "iptables" ]; then
          # Only to clean up sessions left by older versions (new versions no longer create
          # iptables forwarding), so a machine upgraded from an older release - or one that
          # rolled back - does not keep these three rules around.
          log_info "Cleaning up legacy iptables forwarding rules..."
          # || true: iptables -D returns non-zero for a rule already removed elsewhere; eval is the
          # final command of an && list, and that failure makes set -e abort stop_vpn entirely.
          [ -n "${RULE_DNAT_PREROUTING:-}" ] && eval "\$IPTABLES_CMD -t nat -D PREROUTING ${RULE_DNAT_PREROUTING}" 2>/dev/null || true
          [ -n "${RULE_DNAT_OUTPUT:-}" ]   && eval "\$IPTABLES_CMD -t nat -D OUTPUT ${RULE_DNAT_OUTPUT}" 2>/dev/null || true
          [ -n "${RULE_FORWARD:-}" ]       && eval "\$IPTABLES_CMD -D FORWARD ${RULE_FORWARD}" 2>/dev/null || true
        fi
      fi
      [ -f "$GOST_PID_FILE" ] && kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
      if [ -f "$PID_FILE" ]; then
        local oc_pid; oc_pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
        kill "$oc_pid" 2>/dev/null || true
        # Must wait for openconnect to exit before tearing down netns/veth: it has to
        # log out to the gateway over that veth->NAT path (tearing it down first makes
        # it hang on a TLS timeout - see _wait_pid_gone).
        _wait_pid_gone "$oc_pid"
      fi
      cleanup_netns
      ;;
    default|ocproxy)
      log_info "Stopping ${MODE} mode..."
      if [ -f "$PID_FILE" ]; then kill "$(cat "$PID_FILE")" 2>/dev/null || true; fi
      [ "$MODE" = "default" ] && cleanup_ssh_protect_routes
      ;;
    *)
      log_warn "State file not found or mode is unknown, performing generic cleanup..."
      [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null || true
      [ -f "$GOST_PID_FILE" ] && kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
      [ -f "$SOCAT_PID_FILE" ] && kill "$(cat "$SOCAT_PID_FILE")" 2>/dev/null || true
      [ -f "$SOCAT_PID_FILE_V6" ] && kill "$(cat "$SOCAT_PID_FILE_V6")" 2>/dev/null || true
      cleanup_ssh_protect_routes
      cleanup_netns
      ;;
  esac
  
  rm -f "$PID_FILE" "$STATE_FILE" "$GOST_PID_FILE" "$SOCAT_PID_FILE" "$SOCAT_PID_FILE_V6"; log "All temporary files cleaned up. Operation complete."
}

# --- Status Display ---
show_status() {
  local sc; sc=$(_shortcut_state)
  local L=12
  local scc="${C_GREY}"; case "$sc" in *"✓"*) scc="${C_GREEN}";; esac
  if ! is_vpn_running && ! [ -f "$GOST_PID_FILE" ] && ! [ -f "$SOCAT_PID_FILE" ]; then
    echo -e "  ${C_GREY}$(_pad "Status" $L)${C_RESET} ${C_RED}🔴 Stopped${C_RESET}"
    echo -e "  ${C_GREY}$(_pad "Public IPv4" $L)${C_RESET} $(_pub_ip -4 || echo "Query failed")"
    echo -e "  ${C_GREY}$(_pad "Public IPv6" $L)${C_RESET} $(_pub_ip -6 || echo "None / Query failed")"
    echo -e "  ${C_GREY}$(_pad "Shortcut" $L)${C_RESET} ${scc}${sc}${C_RESET}"
  else
    local ACCOUNT_INDEX MODE SOCKS_PORT LISTEN_ADDR VPN_PROTOCOL; [ -f "$STATE_FILE" ] && . "$STATE_FILE" 2>/dev/null || true
    local acct=""; if [ -n "${ACCOUNT_INDEX:-}" ]; then mapfile -t A < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE"); [ "$ACCOUNT_INDEX" -lt "${#A[@]}" ] && acct="$(echo "${A[$ACCOUNT_INDEX]}" | cut -d'|' -f1)"; fi
    local mname="${MODE:-unknown}"; case "${MODE:-}" in default) mname="Default";; ocproxy) mname="ocproxy";; netns) mname="Netns";; esac
    echo -e "  ${C_GREY}$(_pad "Status" $L)${C_RESET} ${C_GREEN}🟢 Running${C_RESET}  ${C_GREY}·${C_RESET}  ${C_BOLD}${mname}${C_RESET} Mode  ${C_GREY}·${C_RESET}  Protocol ${C_CYAN}${VPN_PROTOCOL:-anyconnect}${C_RESET}"
    
    case "${MODE:-}" in
      default)
        echo -e "  ${C_GREY}$(_pad "Egress" $L)${C_RESET} ${C_YELLOW}$(_pub_ip -4 || echo Failed)${C_RESET}  ${C_GREY}·${C_RESET}  IPv6 ${C_YELLOW}$(_pub_ip -6 || echo None/Failed)${C_RESET}"
      ;;
      ocproxy)
        local sip4; sip4=$(_pub_ip -4 "socks5h://127.0.0.1:${SOCKS_PORT}" || echo "Query failed")
        echo -e "  ${C_GREY}$(_pad "SOCKS" $L)${C_RESET} ${LISTEN_ADDR:-127.0.0.1}:${SOCKS_PORT}"
        echo -e "  ${C_GREY}$(_pad "Egress" $L)${C_RESET} ${C_YELLOW}${sip4}${C_RESET}"
      ;;
      netns)
        local f_info; f_info="${FORWARDER:-socat}"
        echo -e "  ${C_GREY}$(_pad "SOCKS" $L)${C_RESET} ${LISTEN_ADDR}:${SOCKS_PORT}  ${C_GREY}(gost $(cat "$GOST_PID_FILE" 2>/dev/null) · ${f_info})${C_RESET}"
        
        local socks_proxy="socks5h://127.0.0.1:${SOCKS_PORT}"
        
        local sip4; sip4=$(_pub_ip -4 "$socks_proxy" || echo "Query failed")
        echo -e "  ${C_GREY}$(_pad "Egress" $L)${C_RESET} ${C_YELLOW}${sip4}${C_RESET}"
        
        local sip6=""
        # The || true is required: _pub_ip returns non-zero when IPv6 is absent and a
        # bare assignment failure would trip set -e, killing the whole script.
        sip6="$(_pub_ip -6 "$socks_proxy" || true)"
        
        if [ -z "$sip6" ] && [ -n "${NETNS_NAME:-}" ]; then
          sip6=$("$IP_CMD" netns exec "${NETNS_NAME}" curl -6 -s --connect-timeout 5 --max-time 10 "${_PUB_PROVIDERS6[0]}" 2>/dev/null | head -n1 | tr -d '\r\n[:space:]' || echo "")
          [ -n "$sip6" ] && sip6="${sip6} ${C_GREY}(Detected inside Netns)${C_RESET}"
        fi
        
        if [ -n "$sip6" ]; then
          echo -e "  ${C_GREY}$(_pad "Egress IPv6" $L)${C_RESET} ${C_YELLOW}${sip6}${C_RESET}"
        else
          echo -e "  ${C_GREY}$(_pad "Egress IPv6" $L)${C_RESET} ${C_YELLOW}Detection timed out or unavailable${C_RESET}"
        fi
      ;;
      *) :;;
    esac
    echo -e "  ${C_GREY}$(_pad "Account" $L)${C_RESET} ${acct:-unknown}  ${C_GREY}·${C_RESET}  PID $(cat "$PID_FILE" 2>/dev/null || echo N/A)  ${C_GREY}·${C_RESET}  Host ${C_YELLOW}$(_pub_ip -4 || echo "Query failed")${C_RESET}"
    echo -e "  ${C_GREY}$(_pad "Shortcut" $L)${C_RESET} ${scc}${sc}${C_RESET}"
  fi
}

# --- Cron & Uninstall ---
manage_cron() {
  # Same as manage_accounts: c must be local, or it clobbers the main menu's choice.
  local c
  while true; do
    clear; title "🗓️ Cron / Daemon Jobs"; sep
    crontab -l 2>/dev/null | grep "$SCRIPT_PATH" || log_info "  No cron jobs found for this script."
    sep
    echo -e "  1) Set up daemon task (check every 5 mins, auto-reconnect)"
    echo -e "  2) Add a scheduled stop task"
    echo -e "  3) Clear all cron jobs for this script"
    echo -e "  4) Back to Main Menu"
    read -rp "Please select [1-4]: " c
    case "$c" in
      1) log_warn "Daemon task currently supports [Default] and [ocproxy] modes only."
         (crontab -l 2>/dev/null | grep -v "_internal_check_health" || true) | { cat; echo "*/5 * * * * $SCRIPT_PATH _internal_check_health"; } | crontab -
         log "Daemon task has been set.";;
      2) read -rp "Enter cron expression (e.g., '0 2 * * *' for 2 AM daily): " exp
         [ -z "$exp" ] && { log_err "Expression cannot be empty"; } || { (crontab -l 2>/dev/null || true; echo "$exp $SCRIPT_PATH stop") | crontab -; log "Scheduled stop task added."; };;
      3) crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true; log "All related cron jobs have been cleared.";;
      4) break;;
      *) log_err "Invalid option";;
    esac; read -n1 -s -p $'\n'"Press any key to return..."
  done
}

# Ask before removing a dependency. The whole point is the difference:
#   installed by this script -> default Y (the user installed it for this script)
#   already on the machine     -> warning + default N, so nothing another program
#                                 still uses gets deleted by accident
# Returns 0 when the user confirmed removal.
_ask_uninstall_dep() {
  local name="$1" desc="$2" ans=""
  if _dep_installed_by_us "$name"; then
    read -rp "Uninstall $name? ($desc, installed by this script) [Y/n]: " ans || ans=""
    [[ "$ans" =~ ^[nN]$ ]] && { log_info "Keeping $name."; return 1; }
    return 0
  fi
  log_warn "$name was not installed by this script (you may have installed it yourself, or something else may use it)."
  read -rp "Are you sure you want to uninstall $name? [y/N]: " ans || ans=""
  if [[ "$ans" =~ ^[yY]$ ]]; then return 0; fi
  log_info "Keeping $name."
  return 1
}

uninstall() {
  local y=""
  read -rp "⚠️  Are you sure you want to uninstall this script and all related configurations? [y/N]: " y || y=""
  [[ "$y" =~ ^[yY]$ ]] || { log_info "Cancelled"; exit 0; }
  log_info "Starting uninstallation..."; stop_vpn
  crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true; log "Cron jobs cleared"
  
  if command -v gost &>/dev/null; then
    if _ask_uninstall_dep gost "SOCKS5 server for Netns mode"; then
      # The official install.sh only understands --install; it has no uninstall branch.
      # Passing --remove (or anything else) drops it into the interactive "pick a
      # version" installer, so the old code could actually reinstall/upgrade gost and
      # then still print "uninstallation attempted" - a false success message.
      # gost is a single binary with no package-manager record, so just delete it.
      log_info "Uninstalling gost..."
      command -v pkill &>/dev/null && pkill -x gost 2>/dev/null || true
      rm -f "$(command -v gost 2>/dev/null)" 2>/dev/null || true
      if command -v gost &>/dev/null; then log_warn "Failed to uninstall gost, please remove it manually."
      else log "gost has been uninstalled."; fi
    fi
  fi
  
  if command -v socat &>/dev/null; then
    if _ask_uninstall_dep socat "Port forwarding for Netns mode (required)"; then
      if command -v apt-get &>/dev/null; then apt-get purge -y socat >/dev/null || true
      elif command -v yum &>/dev/null; then yum remove -y socat >/dev/null || true
      elif command -v dnf &>/dev/null; then dnf remove -y socat >/dev/null || true; fi
      if command -v socat &>/dev/null; then log_warn "Failed to uninstall socat, please remove it manually."
      else log "socat has been uninstalled."; fi
    fi
  fi

  log_warn "OpenConnect / ocproxy are common packages that other programs may also use; choose N if unsure."
  read -rp "Uninstall OpenConnect and ocproxy packages? [y/N]: " yn_oc || yn_oc=""
  if [[ "$yn_oc" =~ ^[yY]$ ]]; then
    if command -v apt-get &>/dev/null; then apt-get purge -y openconnect ocproxy >/dev/null || true
    elif command -v yum &>/dev/null; then yum remove -y openconnect ocproxy >/dev/null || true
    elif command -v dnf &>/dev/null; then dnf remove -y openconnect ocproxy >/dev/null || true; fi
    log "OpenConnect/ocproxy uninstallation attempted."
  fi
  
  rm -f "$ACCOUNTS_FILE"; log "Account file deleted"
  rm -f "$DEPS_MARK_FILE"; rmdir "$DEPS_STATE_DIR" 2>/dev/null || true
  remove_shortcut
  log_info "Deleting script file: $SCRIPT_PATH"; rm -f "$SCRIPT_PATH"; log "Uninstallation complete. Goodbye!"
}

_internal_cron_handler() {
  local a="$1"; shift; check_root
  case "$a" in
    _internal_check_health)
      if ! is_vpn_running && [ -f "$STATE_FILE" ]; then
        log_info "Daemon: Connection loss detected, attempting to reconnect automatically..."; 
        . "$STATE_FILE"; _load_account_by_index "${ACCOUNT_INDEX:-}"
        case "${MODE:-}" in
          default) _start_default_logic ;;
          ocproxy) _start_ocproxy_logic reconnect ;;
          netns) log_err "Daemon: Netns mode does not support auto-reconnect yet, skipping.";;
          *) log_err "Daemon: Unknown recovery mode, cannot reconnect";;
        esac
      fi;;
    *) log_err "Internal cron call error: '$a'";;
  esac
}

# --- Main Menu ---
main_menu() {
  clear
  sep
  echo -e "    ${C_BOLD}🚀  OpenConnect Master Manager${C_RESET}    ${C_GREY}v7.7.7 (Final)${C_RESET}"
  sep
  echo
  # Status is display-only: any lookup failure inside must not break the menu.
  show_status || true
  echo
  echo -e "  ${C_GREEN}1)${C_RESET} 🛡️  ${C_GREEN}Default Mode${C_RESET}${C_GREY} (Global VPN, protects SSH)${C_RESET}"
  echo -e "  ${C_GREEN}2)${C_RESET} 🔌 ${C_GREEN}ocproxy Mode${C_RESET}${C_GREY} (SOCKS5, IPv4 only)${C_RESET}"
  echo -e "  ${C_GREEN}3)${C_RESET} 🌐 ${C_GREEN}Netns Mode${C_RESET}${C_GREY} (SOCKS5, IPv4 + IPv6)${C_RESET}"
  echo -e "  ${C_RED}4)${C_RESET} ⛔ ${C_RED}Stop VPN${C_RESET}"
  sep
  echo -e "  ${C_CYAN}5)${C_RESET} 👤 Manage VPN Accounts"
  echo -e "  ${C_CYAN}6)${C_RESET} 🗓️  Cron / Daemon Jobs"
  echo -e "  ${C_CYAN}7)${C_RESET} 📦 Check / Install Dependencies"
  echo -e "  ${C_CYAN}8)${C_RESET} 🧪 Test Netns IPv6"
  echo -e "  ${C_CYAN}9)${C_RESET} 🗑️  Uninstall"
  echo -e "  ${C_GREY}0)${C_RESET} 🚪 Exit"
  echo
  # Exit when stdin ends (pipe/redirect): otherwise the trailing return 0 makes the
  # menu loop forever, issuing two public-IP lookups per iteration. read fails on EOF.
  read -rp "Please select [0-9]: " c || { echo; log_info "Standard input closed, exiting."; exit 0; }
  case "$c" in
    1) start_default || true;;
    2) start_ocproxy_mode || true;;
    3) start_netns_mode || true;;
    4) stop_vpn || true;;
    5) manage_accounts;;
    6) manage_cron;;
    7) manage_deps;;
    8) if [ -f "$STATE_FILE" ] && grep -q "MODE=netns" "$STATE_FILE"; then
         test_netns_ipv6 || true
       else
         log_err "Netns mode is not running, cannot perform test"
       fi;;
    9) uninstall; exit 0;;
    0) exit 0;;
    *) log_err "Invalid option '$c'";;
  esac
  # For options 5/6, a bare Enter or a wrong key, the AND list above returns 1; and a
  # function whose last statement returns non-zero makes set -e terminate the whole script
  # (measured: pressing Enter at the main menu quit the program). Return explicitly.
  [[ "$c" =~ ^([1-4]|7|8)$ ]] && read -n1 -s -p $'\n'"Press any key to return to the main menu..."
  return 0
}

# --- Script Entrypoint ---
case "${1:-main}" in
  _internal_*) _internal_cron_handler "$@"; exit 0 ;;
  stop) check_root; stop_vpn; exit 0 ;;
  main|*) check_root; _ensure_shortcut; while true; do main_menu; done ;;
esac
