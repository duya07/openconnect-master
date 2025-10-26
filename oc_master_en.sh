#!/bin/bash
# =================================================================
#   OpenConnect Master Manager - v7.7.7 (Final)
#   - Final: Simplified ocproxy mode, removed remote connection option, listens locally by default.
#   - Fix(Netns): Enhanced IPv6 detection in show_status, improving success rate through multiple methods (increased timeout, fallback check points, direct netns connection).
#   - Enhancement(Netns): socat forwarding now supports dual-stack (IPv4 & IPv6) listening.
#   - New(Netns): Added active IPv6 connectivity test function at startup and in the menu.
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
sep()      { echo -e "${C_GREY}--------------------------------------------------------${C_RESET}"; }
check_root(){ [ "$EUID" -eq 0 ] || { log_err "Please run as root"; exit 1; }; }

# --- Interrupt Handling ---
cleanup_on_interrupt() {
  log_err "\nOperation interrupted by user (Ctrl+C). Performing emergency cleanup..."
  stop_vpn
  exit 1
}

# --- Dependency Checks ---
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
ensure_pkg_openconnect() { command -v openconnect &>/dev/null || { _pkg_install openconnect; command -v openconnect &>/dev/null || { log_err "Failed to install openconnect"; exit 1; }; log "OpenConnect is ready"; }; }
ensure_pkg_ocproxy()     { command -v ocproxy     &>/dev/null || { _pkg_install ocproxy; command -v ocproxy &>/dev/null || { log_err "Failed to install ocproxy"; exit 1; }; log "ocproxy is ready"; }; }
ensure_pkg_iptables()    { command -v iptables    &>/dev/null || { _pkg_install iptables; command -v iptables &>/dev/null || { log_err "Failed to install iptables"; exit 1; }; log "iptables is ready"; }; }
ensure_cmd_ss()          { command -v ss &>/dev/null || { _pkg_install iproute2 || _pkg_install iproute; log "iproute2 is ready"; }; }
ensure_cmd_gost() {
  command -v gost &>/dev/null && return 0
  log_warn "Netns mode requires 'gost' as a SOCKS5 server."
  read -rp "Do you want to auto-install gost using the official script now? [Y/n]: " yn
  [[ "$yn" =~ ^[nN]$ ]] && { log_err "User cancelled installation. Netns mode cannot be started."; return 1; }
  
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
  log "gost has been successfully installed."
  return 0
}
ensure_cmd_socat() {
  command -v socat &>/dev/null && return 0
  log_warn "Netns mode recommends using 'socat' for port forwarding."
  read -rp "Do you want to install socat now? [Y/n]: " yn
  [[ "$yn" =~ ^[nN]$ ]] && { log_info "iptables will be used as a fallback."; return 1; }
  _pkg_install socat
  command -v socat &>/dev/null || { log_warn "socat installation failed, will use iptables."; return 1; }
  log "socat has been installed."
  return 0
}
check_atd() { if ! command -v at &>/dev/null || ! systemctl is-active --quiet atd; then log_warn "at/atd is missing or not running, attempting to install and start..."; _pkg_install at; systemctl enable --now atd 2>/dev/null || log_err "Failed to start atd automatically"; fi; }

# --- IPv6 Connectivity Test ---
test_netns_ipv6() {
  local test_passed=0
  log_info "Testing IPv6 connectivity inside Netns..."
  if ! "$IP_CMD" netns list | grep -q "${NETNS_NAME}"; then log_err "Netns ${NETNS_NAME} does not exist, cannot perform test."; return 1; fi
  
  # Test 1: Check for IPv6 address
  if "$IP_CMD" netns exec "${NETNS_NAME}" ip -6 addr show 2>/dev/null | grep -q "inet6.*scope global"; then
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
_check_port_free() { local port="$1"; ensure_cmd_ss || true; if command -v ss &>/dev/null && ss -lntup 2>/dev/null | grep -q ":${port} "; then return 1; fi; return 0; }

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
  log "Netns base environment has been cleaned up."
}

# --- Account Management ---
manage_accounts() {
  [ -f "$ACCOUNTS_FILE" ] || { tee "$ACCOUNTS_FILE" >/dev/null <<'EOT'
# Format: Display Name|Username|Password|VPN Host|Auth Group(Optional)
EOT
    chmod 600 "$ACCOUNTS_FILE" || true; }
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
         grep -vF "${A[$((i-1))]}" "$ACCOUNTS_FILE" > "${ACCOUNTS_FILE}.tmp" && mv "${ACCOUNTS_FILE}.tmp" "$ACCOUNTS_FILE"; log "Deleted"; read -n1 -s -p "Press any key to continue";;
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
    show_status
  else
    trap - SIGINT # Failure, remove the trap
    log_err "Startup process failed, please check the logs."
    stop_vpn # Ensure cleanup is also run on internal function failure
  fi
}

start_default() { is_vpn_running && { log_err "VPN is already running"; return; }; ensure_pkg_openconnect; select_account || return; _execute_with_safety_net "_start_default_logic"; }
_start_default_logic() {
  setup_ssh_protect_routes
  { echo "MODE=default"; echo "ACCOUNT_INDEX=$ACCOUNT_INDEX"; } | tee -a "$STATE_FILE" >/dev/null
  log_info "Connecting to VPN [Default Mode]: $VPN_HOST ..."
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol=anyconnect --user="$VPN_USER" --passwd-on-stdin -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "${oc_cmd[@]}"
  log_info "Waiting for TUN interface to be ready..."; for ((i=0;i<15;i++)); do if is_vpn_running && ip link show 2>/dev/null | grep -q 'tun.*UP'; then log "VPN connected successfully (PID=$(cat "$PID_FILE"))"; return 0; fi; sleep 1; done
  log_err "VPN connection failed or timed out"; return 1
}

start_ocproxy_mode() { is_vpn_running && { log_err "VPN is already running"; return; }; ensure_pkg_ocproxy; select_account || return; _execute_with_safety_net "_start_ocproxy_logic"; }
_start_ocproxy_logic() {
  local socks_port
  local listen_addr="127.0.0.1" # [Final] Simplified: listen locally by default, remove remote option
  while true;do read -rp "Please enter the SOCKS5 listening port (e.g. 1080): " socks_port; [[ "$socks_port" =~ ^[0-9]+$ ]]&&[ "$socks_port" -ge 1 ]&&[ "$socks_port" -le 65535 ]||{ log_err "Invalid port";continue; }; _check_port_free "$socks_port"||{ log_err "Port is already in use";continue; }; break; done
  
  log_info "Starting ocproxy mode (Listening on: $listen_addr)...";
  # [Final] Simplified: removed unused allow_arg variable
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol=anyconnect --user="$VPN_USER" --passwd-on-stdin --script-tun --script "ocproxy -k 30 -D $socks_port" -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "${oc_cmd[@]}"
  
  log_info "Waiting for ocproxy to start..."; for ((i=0;i<10;i++)); do if is_vpn_running; then log "ocproxy connected successfully (PID=$(cat "$PID_FILE"))"; echo "MODE=ocproxy">"$STATE_FILE";echo "ACCOUNT_INDEX=$ACCOUNT_INDEX" >> "$STATE_FILE";echo "SOCKS_PORT=$socks_port" >> "$STATE_FILE";echo "LISTEN_ADDR=$listen_addr" >> "$STATE_FILE"; return 0; fi; sleep 1; done
  log_err "ocproxy connection failed or timed out"; return 1
}

start_netns_mode() {
  is_vpn_running && { log_err "VPN is already running"; return; }
  ensure_cmd_gost || return
  ensure_cmd_socat || true # Continue even if socat fails, use iptables
  select_account || return
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
  
  log_info "Starting OpenConnect in Netns...";
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol=anyconnect --user="$VPN_USER" --passwd-on-stdin -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "$IP_CMD" netns exec "${NETNS_NAME}" "${oc_cmd[@]}"
  
  log_info "Waiting for OpenConnect to establish TUN interface...";
  for ((i=0; i<20; i++)); do
    if [ -f "$PID_FILE" ] && "$IP_CMD" netns pids "${NETNS_NAME}" | grep -qF "$(cat "$PID_FILE")" && \
       "$IP_CMD" netns exec "${NETNS_NAME}" ip link show 2>/dev/null | grep -q 'tun.*UP'; then
      log "OpenConnect TUN interface is ready (PID=$(cat "$PID_FILE"))"; sleep 2; break
    fi
    sleep 1
  done
  
  if ! "$IP_CMD" netns exec "${NETNS_NAME}" ip link show 2>/dev/null | grep -q 'tun.*UP'; then
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
  local forwarder_mode="" RULE_DNAT_PREROUTING="" RULE_DNAT_OUTPUT="" RULE_FORWARD="" socat_pid_v4="" socat_pid_v6=""
  if command -v socat &>/dev/null; then
    socat TCP4-LISTEN:"${socks_port}",bind="${listen_addr}",fork,reuseaddr TCP4:"${VETH_NS_IP}:${socks_port}" >/dev/null 2>&1 &
    socat_pid_v4=$!; echo "$socat_pid_v4" > "$SOCAT_PID_FILE"
    
    if [[ "$listen_addr" == "0.0.0.0" ]] || [[ "$listen_addr" == "::" ]]; then
      socat TCP6-LISTEN:"${socks_port}",ipv6only=1,fork,reuseaddr TCP4:"${VETH_NS_IP}:${socks_port}" >/dev/null 2>&1 &
      socat_pid_v6=$!; echo "$socat_pid_v6" > "$SOCAT_PID_FILE_V6"
      log "Using socat for port forwarding (IPv4 PID: $socat_pid_v4, IPv6 PID: $socat_pid_v6)"
    else
      log "Using socat for port forwarding (PID: $socat_pid_v4)"
    fi
    forwarder_mode="socat"
  else
    log_info "socat not found, using iptables DNAT as a fallback."
    RULE_DNAT_PREROUTING="-p tcp --dport ${socks_port} -j DNAT --to-destination ${VETH_NS_IP}:${socks_port}"
    [ "$listen_addr" != "0.0.0.0" ] && RULE_DNAT_PREROUTING="-p tcp -d ${listen_addr} --dport ${socks_port} -j DNAT --to-destination ${VETH_NS_IP}:${socks_port}"
    RULE_DNAT_OUTPUT="-p tcp -o lo --dport ${socks_port} -j DNAT --to-destination ${VETH_NS_IP}:${socks_port}"
    RULE_FORWARD="-i ${VETH_HOST} -d ${VETH_NS_IP} -p tcp --dport ${socks_port} -j ACCEPT"
    
    "$IPTABLES_CMD" -t nat -A PREROUTING ${RULE_DNAT_PREROUTING}
    "$IPTABLES_CMD" -t nat -A OUTPUT ${RULE_DNAT_OUTPUT}
    "$IPTABLES_CMD" -A FORWARD ${RULE_FORWARD}
    log "Using iptables for port forwarding"
    forwarder_mode="iptables"
  fi
  
  {
    echo "MODE=netns"; echo "ACCOUNT_INDEX=$ACCOUNT_INDEX"; echo "SOCKS_PORT=$socks_port";
    echo "LISTEN_ADDR=$listen_addr"; echo "GOST_PID=$gost_pid"; echo "FORWARDER=${forwarder_mode}";
    [ -n "$socat_pid_v4" ] && echo "SOCAT_PID=${socat_pid_v4}";
    [ -n "$socat_pid_v6" ] && echo "SOCAT_PID_V6=${socat_pid_v6}";
    [ "$forwarder_mode" = "iptables" ] && {
      echo "RULE_DNAT_PREROUTING='${RULE_DNAT_PREROUTING}'"
      echo "RULE_DNAT_OUTPUT='${RULE_DNAT_OUTPUT}'"
      echo "RULE_FORWARD='${RULE_FORWARD}'"
    }
  } > "$STATE_FILE"
  
  return 0
}

# --- Stop & Cleanup ---
cleanup_ssh_protect_routes() {
  local vps4="" vps6=""
  if [ -f "$STATE_FILE" ]; then
    log_info "🔍 Loading route info from state file for precise cleanup..."
    vps4=$(grep '^VPS4=' "$STATE_FILE" | cut -d'=' -f2)
    vps6=$(grep '^VPS6=' "$STATE_FILE" | cut -d'=' -f2)
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
  if ! is_vpn_running && ! [ -f "$GOST_PID_FILE" ] && ! [ -f "$SOCAT_PID_FILE" ]; then log_info "VPN is not running"; return; fi
  log_info "Stopping VPN and cleaning up environment...";
  local MODE; [ -f "$STATE_FILE" ] && MODE=$(grep '^MODE=' "$STATE_FILE" | cut -d'=' -f2)

  case "${MODE:-unknown}" in
    netns)
      log_info "Stopping netns mode..."
      if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE" 2>/dev/null || true
        if [ "${FORWARDER:-}" = "socat" ]; then
          [ -f "$SOCAT_PID_FILE" ] && kill "$(cat "$SOCAT_PID_FILE")" 2>/dev/null || true
          [ -f "$SOCAT_PID_FILE_V6" ] && kill "$(cat "$SOCAT_PID_FILE_V6")" 2>/dev/null || true
        elif [ "${FORWARDER:-}" = "iptables" ]; then
          log_info "Cleaning up Netns iptables forwarding rules..."
          [ -n "${RULE_DNAT_PREROUTING:-}" ] && eval "\$IPTABLES_CMD -t nat -D PREROUTING ${RULE_DNAT_PREROUTING}" 2>/dev/null
          [ -n "${RULE_DNAT_OUTPUT:-}" ]   && eval "\$IPTABLES_CMD -t nat -D OUTPUT ${RULE_DNAT_OUTPUT}" 2>/dev/null
          [ -n "${RULE_FORWARD:-}" ]       && eval "\$IPTABLES_CMD -D FORWARD ${RULE_FORWARD}" 2>/dev/null
        fi
      fi
      [ -f "$GOST_PID_FILE" ] && kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
      [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null || true
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
  local ip_provider="ip.p3terx.com"; local curl_opts=(-s -A "Mozilla/5.0" --connect-timeout 4 --max-time 8)
  sep
  if ! is_vpn_running && ! [ -f "$GOST_PID_FILE" ] && ! [ -f "$SOCAT_PID_FILE" ]; then
    title "  VPN Status: ${C_RED}🔴 Stopped${C_RESET}"
    echo -e "    ${C_BOLD}Host Public IPv4:${C_RESET} $($CURL_CMD -4 "${curl_opts[@]}" "$ip_provider" | head -n1 || echo "Query failed")"
    echo -e "    ${C_BOLD}Host Public IPv6:${C_RESET} $($CURL_CMD -6 "${curl_opts[@]}" "$ip_provider" | head -n1 || echo "None/Query failed")"
  else
    local ACCOUNT_INDEX MODE SOCKS_PORT LISTEN_ADDR; [ -f "$STATE_FILE" ] && . "$STATE_FILE" 2>/dev/null || true
    title "  VPN Status: ${C_GREEN}🟢 Running${C_RESET} (OpenConnect PID: $(cat "$PID_FILE" 2>/dev/null || echo N/A))"
    if [ -n "${ACCOUNT_INDEX:-}" ]; then mapfile -t A < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE"); [ "$ACCOUNT_INDEX" -lt "${#A[@]}" ] && echo -e "    ${C_BOLD}Using Account:${C_RESET} $(echo "${A[$ACCOUNT_INDEX]}" | cut -d'|' -f1)"; fi
    
    case "${MODE:-}" in
      default)
        echo -e "    ${C_BOLD}Running Mode:${C_RESET} 🛡️  Default (Global) Mode"
        echo -e "    ${C_BOLD}VPN Egress IPv4:${C_RESET} ${C_YELLOW}$($CURL_CMD -4 "${curl_opts[@]}" "$ip_provider"|head -n1||echo Failed)${C_RESET}"
        echo -e "    ${C_BOLD}VPN Egress IPv6:${C_RESET} ${C_YELLOW}$($CURL_CMD -6 "${curl_opts[@]}" "$ip_provider"|head -n1||echo None/Failed)${C_RESET}"
      ;;
      ocproxy)
        echo -e "    ${C_BOLD}Running Mode:${C_RESET} 🔌 ocproxy Proxy ${C_GREY}(IPv4 only)${C_RESET}"
        echo -e "    ${C_BOLD}SOCKS Address:${C_RESET} ${LISTEN_ADDR:-127.0.0.1}:${SOCKS_PORT}"
        local sip4; sip4=$($CURL_CMD -x "socks5h://127.0.0.1:${SOCKS_PORT}" -4 "${curl_opts[@]}" "$ip_provider"|head -n1||echo "Query failed")
        echo -e "    ${C_BOLD}SOCKS Egress IPv4:${C_RESET} ${C_YELLOW}${sip4}${C_RESET}"
        echo -e "    ${C_BOLD}Host Public IPv4:${C_RESET} $($CURL_CMD -4 "${curl_opts[@]}" "$ip_provider"|head -n1||echo Failed)"
      ;;
      netns)
        echo -e "    ${C_BOLD}Running Mode:${C_RESET} 🌐 Network Namespace Proxy ${C_GREEN}(IPv4+IPv6)${C_RESET}"
        local f_info; if [[ "${FORWARDER:-}" == "socat" ]]; then f_info="socat"; else f_info="iptables"; fi
        echo -e "    ${C_BOLD}SOCKS Address:${C_RESET} ${LISTEN_ADDR}:${SOCKS_PORT} ${C_GREY}(gost PID: $(cat "$GOST_PID_FILE" 2>/dev/null), by ${f_info})${C_RESET}"
        
        local socks_proxy="socks5h://127.0.0.1:${SOCKS_PORT}"
        local curl_opts_socks=(-s -A "Mozilla/5.0" --connect-timeout 8 --max-time 15)
        
        local sip4; sip4=$($CURL_CMD -x "$socks_proxy" -4 "${curl_opts_socks[@]}" "$ip_provider" 2>/dev/null | head -n1 || echo "Query failed")
        echo -e "    ${C_BOLD}SOCKS Egress IPv4:${C_RESET} ${C_YELLOW}${sip4}${C_RESET}"
        
        local sip6="";
        sip6=$($CURL_CMD -x "$socks_proxy" -6 "${curl_opts_socks[@]}" "$ip_provider" 2>/dev/null | head -n1 || echo "")
        
        if [ -z "$sip6" ] || [[ "$sip6" == *"Query failed"* ]]; then
          sip6=$($CURL_CMD -x "$socks_proxy" -6 "${curl_opts_socks[@]}" "https://api64.ipify.org" 2>/dev/null || echo "")
        fi
        
        if [ -z "$sip6" ] && [ -n "${NETNS_NAME:-}" ]; then
          sip6=$("$IP_CMD" netns exec "${NETNS_NAME}" curl -6 -s --connect-timeout 5 --max-time 10 "$ip_provider" 2>/dev/null | head -n1 || echo "")
          [ -n "$sip6" ] && sip6="${sip6} ${C_GREY}(Detected inside Netns)${C_RESET}"
        fi
        
        if [ -n "$sip6" ] && [[ "$sip6" != *"Query failed"* ]]; then
          echo -e "    ${C_BOLD}SOCKS Egress IPv6:${C_RESET} ${C_YELLOW}${sip6}${C_RESET}"
        else
          echo -e "    ${C_BOLD}SOCKS Egress IPv6:${C_RESET} ${C_YELLOW}Detection timed out or unavailable${C_RESET}"
        fi
        
        echo -e "    ${C_BOLD}Host Public IPv4:${C_RESET} $($CURL_CMD -4 "${curl_opts[@]}" "$ip_provider" 2>/dev/null | head -n1 || echo Failed)"
      ;;
      *) echo "    ${C_BOLD}Running Mode:${C_RESET} Unknown";;
    esac
  fi
  sep
}

# --- Cron & Uninstall ---
manage_cron() {
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

uninstall() {
  read -rp "⚠️  Are you sure you want to uninstall this script and all related configurations? [y/N]: " y; [[ "$y" =~ ^[yY]$ ]] || { log_info "Cancelled"; exit 0; }
  log_info "Starting uninstallation..."; stop_vpn
  crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true; log "Cron jobs cleared"
  
  if command -v gost &>/dev/null; then
    read -rp "Uninstall gost? (was auto-installed by Netns mode) [Y/n]: " yn_gost
    if [[ ! "$yn_gost" =~ ^[nN]$ ]]; then
      log_info "Attempting to uninstall gost using the official script..."
      if command -v curl &>/dev/null; then
         bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --remove || log_warn "gost uninstallation script failed."
      else
         log_warn "curl command not found, attempting to remove gost file directly..."; rm -f /usr/local/bin/gost
      fi; log "gost uninstallation attempted."
    fi
  fi
  
  if command -v socat &>/dev/null; then
    read -rp "Uninstall socat? (was auto-installed by Netns mode) [Y/n]: " yn_socat
    if [[ ! "$yn_socat" =~ ^[nN]$ ]]; then
      if command -v apt-get &>/dev/null; then apt-get purge -y socat >/dev/null || true
      elif command -v yum &>/dev/null; then yum remove -y socat >/dev/null || true
      elif command -v dnf &>/dev/null; then dnf remove -y socat >/dev/null || true; fi
      log "socat uninstallation attempted."
    fi
  fi

  read -rp "Uninstall OpenConnect and ocproxy packages? [y/N]: " yn_oc
  if [[ "$yn_oc" =~ ^[yY]$ ]]; then
    if command -v apt-get &>/dev/null; then apt-get purge -y openconnect ocproxy >/dev/null || true
    elif command -v yum &>/dev/null; then yum remove -y openconnect ocproxy >/dev/null || true
    elif command -v dnf &>/dev/null; then dnf remove -y openconnect ocproxy >/dev/null || true; fi
    log "OpenConnect/ocproxy uninstallation attempted."
  fi
  
  rm -f "$ACCOUNTS_FILE"; log "Account file deleted"
  log_info "Deleting script file: $SCRIPT_PATH"; rm -f "$SCRIPT_PATH"; log "Uninstallation complete. Goodbye!"
}

_internal_cron_handler() {
  local a="$1"; shift; check_root
  case "$a" in
    _internal_check_health)
      if ! is_vpn_running && [ -f "$STATE_FILE" ]; then
        log_info "Daemon: Connection loss detected, attempting to reconnect automatically..."; 
        . "$STATE_FILE"; _load_account_by_index "${ACCOUNT_INDEX}"
        case "${MODE:-}" in
          default) _start_default_logic ;;
          ocproxy) _start_ocproxy_logic ;;
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
  echo -e "${C_BOLD}========================================================${C_RESET}"
  echo -e "${C_BOLD}  🚀 OpenConnect Master Manager v7.7.7 (Final) 🚀${C_RESET}"
  echo -e "${C_BOLD}========================================================${C_RESET}"
  show_status
  title "Main Menu:"
  echo -e "  ${C_GREEN}1) Start: 🛡️  Default Mode (Global VPN, protects SSH)${C_RESET}"
  echo -e "  ${C_GREEN}2) Start: 🔌 ocproxy Mode (SOCKS5, IPv4 only)${C_RESET}"
  echo -e "  ${C_GREEN}3) Start: 🌐 Netns Mode (SOCKS5, full-featured IPv4+IPv6)${C_RESET}"
  echo -e "  ${C_RED}4) Stop VPN${C_RESET}"
  sep
  echo -e "  5) ⚙️  Manage VPN Accounts"
  echo -e "  6) 🗓️  Setup Cron / Daemon Jobs"
  echo -e "  7) 📦 Check/Install Dependencies"
  echo -e "  8) 🧪 ${C_CYAN}Test Netns IPv6 Connectivity${C_RESET}"
  echo -e "  9) 🗑️  Uninstall"
  echo -e "  0) 🚪 Exit"
  echo
  read -rp "Please select [0-9]: " c
  case "$c" in
    1) start_default || true;;
    2) start_ocproxy_mode || true;;
    3) start_netns_mode || true;;
    4) stop_vpn || true;;
    5) manage_accounts;;
    6) manage_cron;;
    7) ensure_pkg_openconnect; ensure_pkg_ocproxy; ensure_cmd_gost || true; ensure_cmd_socat || true;;
    8) if [ -f "$STATE_FILE" ] && grep -q "MODE=netns" "$STATE_FILE"; then
         test_netns_ipv6 || true
       else
         log_err "Netns mode is not running, cannot perform test"
       fi;;
    9) uninstall; exit 0;;
    0) exit 0;;
    *) log_err "Invalid option '$c'";;
  esac
  [[ "$c" =~ ^[1-4,7,8]$ ]] && read -n1 -s -p $'\n'"Press any key to return to the main menu..."
}

# --- Script Entrypoint ---
case "${1:-main}" in
  _internal_*) _internal_cron_handler "$@"; exit 0 ;;
  stop) check_root; stop_vpn; exit 0 ;;
  main|*) check_root; while true; do main_menu; done ;;
esac
